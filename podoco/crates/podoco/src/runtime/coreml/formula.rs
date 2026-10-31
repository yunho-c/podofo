//! All formula models, tensors, and states are confined to one owner thread.
use super::{
    call, fallible, invalid, pool,
    tensor::{self, Layout},
};
use crate::{Error, ErrorCode, Result, formula::FormulaBundle, options::ComputePolicy};
use cidre::{arc, ml, ml::FeatureProvider, ns};
use half::f16;
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    marker::PhantomData,
    path::Path,
    rc::Rc,
};

const CROSS: &[usize] = &[16, 16, 144, 32];
/// Two simultaneously live states and one layer's read/write scratch at promotion.
pub(crate) const CACHE_PEAK: u64 = 4_194_304 + 33_554_432 + 262_144 + 2_097_152;
pub(crate) const NATIVE_TENSORS: u64 = 12 * 1024 * 1024;

struct Embeddings {
    file: File,
    rows: usize,
}
impl Embeddings {
    fn open(path: &Path, rows: usize) -> Result<Self> {
        let mut file = File::open(path).map_err(|e| Error::io(path, e))?;
        let mut header = [0u8; 128];
        file.read_exact(&mut header)
            .map_err(|e| Error::io(path, e))?;
        let desc = std::str::from_utf8(&header[10..]).map_err(|_| invalid("invalid NPY header"))?;
        if &header[..8] != b"\x93NUMPY\x01\x00"
            || u16::from_le_bytes([header[8], header[9]]) != 118
            || !desc.contains("'descr': '<f4'")
            || !desc.contains("'fortran_order': False")
            || !desc.contains(&format!("'shape': ({rows}, 512)"))
            || file.metadata().map_err(|e| Error::io(path, e))?.len()
                != 128 + (rows * 512 * 4) as u64
        {
            return Err(invalid("unsupported embedding table contract"));
        }
        Ok(Self { file, rows })
    }
    fn row(&mut self, row: usize, output: &mut [f32; 512]) -> Result<()> {
        if row >= self.rows {
            return Err(invalid("embedding index out of range"));
        }
        let mut bytes = [0u8; 2048];
        self.file
            .seek(SeekFrom::Start(128 + (row * 2048) as u64))
            .and_then(|_| self.file.read_exact(&mut bytes))
            .map_err(|e| Error::new(ErrorCode::Io, e.to_string()))?;
        for (v, b) in output.iter_mut().zip(bytes.chunks_exact(4)) {
            *v = f32::from_le_bytes(b.try_into().expect("four bytes"));
        }
        Ok(())
    }
}
struct Decoder {
    model: arc::R<ml::Model>,
    capacity: usize,
}
struct Decoding {
    state: arc::R<ml::State>,
    provider: arc::R<ml::DictionaryFeatureProvider>,
    embedding: arc::R<ml::MultiArray>,
    mask: arc::R<ml::MultiArray>,
    write_mask: arc::R<ml::MultiArray>,
    mask_host: Vec<u16>,
    write_host: Vec<u16>,
    span: u64,
}
pub(crate) struct FormulaModel {
    encoder: arc::R<ml::Model>,
    decoders: [Decoder; 2],
    input: arc::R<ml::MultiArray>,
    input_provider: arc::R<ml::DictionaryFeatureProvider>,
    tokens: Embeddings,
    positions: Embeddings,
    native_limit: u64,
    cache_limit: u64,
    _thread: PhantomData<Rc<()>>,
}
pub(crate) struct Generation {
    pub(crate) ids: Vec<u32>,
    pub(crate) native_peak: u64,
    pub(crate) cache_peak: u64,
    pub(crate) promotions: u32,
}
fn array(shape: &[usize], dtype: ml::MultiArrayDType) -> Result<arc::R<ml::MultiArray>> {
    let shape = shape
        .iter()
        .map(|&n| ns::Number::with_i64(n as i64))
        .collect::<Vec<_>>();
    let refs = shape.iter().map(|n| n.as_ref()).collect::<Vec<_>>();
    fallible("allocate formula tensor", || {
        ml::MultiArray::with_shape(ns::Array::from_slice(&refs), dtype)
    })
}
fn provider(tensors: &[(&str, &ml::MultiArray)]) -> Result<arc::R<ml::DictionaryFeatureProvider>> {
    let mut values = ns::DictionaryMut::<ns::String, ns::Id>::with_capacity(tensors.len());
    for (name, array) in tensors {
        values.insert(
            &ns::String::with_str(name),
            ml::FeatureValue::with_multi_array(array).as_id_ref(),
        );
    }
    fallible("create formula features", || {
        ml::DictionaryFeatureProvider::with_dictionary(&values)
    })
}
fn output(
    features: &ml::AnyFeatureProvider,
    name: &str,
    shape: &[usize],
    dtype: ml::MultiArrayDType,
) -> Result<(arc::R<ml::MultiArray>, u64)> {
    let value = features
        .feature_value_for_name(&ns::String::with_str(name))
        .ok_or_else(|| invalid("missing formula output"))?;
    let a = value
        .multi_array()
        .ok_or_else(|| invalid("formula output is not a tensor"))?;
    let span = Layout::inspect_typed(&a, shape, dtype)?.span as u64;
    Ok((a, span))
}
fn validate(
    features: &ns::Dictionary<ns::String, ml::FeatureDesc>,
    specs: &[(&str, &[usize], ml::MultiArrayDType)],
) -> Result<()> {
    if features.len() != specs.len() {
        return Err(invalid("unexpected formula feature count"));
    }
    for (name, shape, dtype) in specs {
        let f = features
            .get(&ns::String::with_str(name))
            .ok_or_else(|| invalid("missing formula feature"))?;
        let c = f
            .multi_array_constraint()
            .ok_or_else(|| invalid("formula feature is not a tensor"))?;
        if f.is_optional()
            || c.data_type() != *dtype
            || c.shape().iter().map(|n| n.as_i64()).collect::<Vec<_>>()
                != shape.iter().map(|&n| n as i64).collect::<Vec<_>>()
        {
            return Err(invalid(format!("incompatible formula feature: {name}")));
        }
    }
    Ok(())
}
fn state_shape(key: bool, capacity: usize) -> [usize; 4] {
    if key {
        [1, 16, 32, capacity]
    } else {
        [1, 16, capacity, 32]
    }
}
impl Decoder {
    fn validate(&self) -> Result<()> {
        let desc = self.model.model_desc();
        let f16 = ml::MultiArrayDType::F16;
        validate(
            &desc.input_descs_by_name(),
            &[
                ("embedding", &[1, 1, 512], f16),
                ("mask", &[1, 1, 1, self.capacity], f16),
                ("write_mask", &[1, 1, 1, self.capacity], f16),
                ("cross_kv", CROSS, f16),
            ],
        )?;
        validate(
            &desc.output_descs_by_name(),
            &[("logits", &[1, 50000], ml::MultiArrayDType::F32)],
        )?;
        let states = desc.state_descs_by_name();
        if states.len() != 16 {
            return Err(invalid("unexpected decoder state count"));
        }
        for layer in 0..8 {
            for key in [true, false] {
                let name = ns::String::with_str(&format!(
                    "layers_{layer}_{}_cache",
                    if key { "key" } else { "value" }
                ));
                let f = states
                    .get(&name)
                    .ok_or_else(|| invalid("missing decoder state"))?;
                let c = f
                    .state_constraint()
                    .ok_or_else(|| invalid("missing state constraint"))?;
                if c.data_type() != f16
                    || c.buffer_shape()
                        .iter()
                        .map(|n| n.as_i64())
                        .collect::<Vec<_>>()
                        != state_shape(key, self.capacity).map(|n| n as i64)
                {
                    return Err(invalid("invalid decoder cache shape/dtype"));
                }
            }
        }
        Ok(())
    }
    fn start(&self, cross: &ml::MultiArray, cache_limit: u64) -> Result<Decoding> {
        super::check_budget((8 * 2 * 512 * self.capacity * 2) as u64, cache_limit)?;
        let state = self.model.new_state();
        let mut span = 0u64;
        for layer in 0..8 {
            for key in [true, false] {
                let name = ns::String::with_str(&format!(
                    "layers_{layer}_{}_cache",
                    if key { "key" } else { "value" }
                ));
                let mut result = Err(invalid("state access callback did not run"));
                state.with_multi_array_for_state_named(&name, |a| {
                    result = Layout::inspect_typed(
                        a,
                        &state_shape(key, self.capacity),
                        ml::MultiArrayDType::F16,
                    )
                    .map(|v| v.span as u64)
                });
                span = span
                    .checked_add(result?)
                    .ok_or_else(|| invalid("cache span overflow"))?;
                super::check_budget(span, cache_limit)?;
            }
        }
        let embedding = array(&[1, 1, 512], ml::MultiArrayDType::F16)?;
        let mask = array(&[1, 1, 1, self.capacity], ml::MultiArrayDType::F16)?;
        let write_mask = array(&[1, 1, 1, self.capacity], ml::MultiArrayDType::F16)?;
        let provider = provider(&[
            ("embedding", &embedding),
            ("mask", &mask),
            ("write_mask", &write_mask),
            ("cross_kv", cross),
        ])?;
        Ok(Decoding {
            state,
            provider,
            embedding,
            mask,
            write_mask,
            mask_host: vec![f16::from_f32(-10000.).to_bits(); self.capacity],
            write_host: vec![0; self.capacity],
            span,
        })
    }
}
impl FormulaModel {
    pub(crate) fn load(
        bundle: &FormulaBundle,
        policy: ComputePolicy,
        native_limit: u64,
        cache_limit: u64,
    ) -> Result<Self> {
        pool(|| {
            call("open formula models", || {
                super::check_budget(NATIVE_TENSORS, native_limit)?;
                super::check_budget(CACHE_PEAK, cache_limit)?;
                let mut cfg = ml::ModelCfg::new();
                cfg.set_compute_units(match policy {
                    ComputePolicy::CpuOnly => ml::ComputeUnits::Cpu,
                    ComputePolicy::CpuAndNeuralEngine => ml::ComputeUnits::CpuNe,
                    ComputePolicy::All => ml::ComputeUnits::All,
                });
                let load = |name: &str| -> Result<_> {
                    let path = bundle.directory().join(format!("compiled/{name}.mlmodelc"));
                    let url = ns::Url::with_fs_path_str(
                        path.to_str()
                            .ok_or_else(|| invalid("non-UTF-8 formula path"))?,
                        true,
                    );
                    fallible("load compiled formula model", || {
                        ml::Model::with_cfg(&url, &cfg)
                    })
                };
                let encoder = load("encoder")?;
                let desc = encoder.model_desc();
                validate(
                    &desc.input_descs_by_name(),
                    &[("pixel_values", &[1, 3, 768, 768], ml::MultiArrayDType::F32)],
                )?;
                validate(
                    &desc.output_descs_by_name(),
                    &[
                        ("hidden", &[1, 144, 512], ml::MultiArrayDType::F32),
                        ("cross_kv", CROSS, ml::MultiArrayDType::F16),
                    ],
                )?;
                if !desc.state_descs_by_name().is_empty() {
                    return Err(invalid("encoder unexpectedly stateful"));
                }
                let decoders = [
                    Decoder {
                        model: load("decoder-c256")?,
                        capacity: 256,
                    },
                    Decoder {
                        model: load("decoder-c2048")?,
                        capacity: 2048,
                    },
                ];
                for decoder in &decoders {
                    decoder.validate()?;
                }
                let input = array(&[1, 3, 768, 768], ml::MultiArrayDType::F32)?;
                let input_provider = provider(&[("pixel_values", &input)])?;
                Ok(Self {
                    encoder,
                    decoders,
                    input,
                    input_provider,
                    tokens: Embeddings::open(
                        &bundle.directory().join("export/token_embeddings.npy"),
                        50000,
                    )?,
                    positions: Embeddings::open(
                        &bundle.directory().join("export/position_embeddings.npy"),
                        2562,
                    )?,
                    native_limit,
                    cache_limit,
                    _thread: PhantomData,
                })
            })
        })
    }
    pub(crate) fn generate(
        &mut self,
        pixels: &[f32],
        max_tokens: usize,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Generation> {
        let check = || {
            if cancel() {
                Err(Error::new(
                    ErrorCode::Cancelled,
                    "formula recognition cancelled",
                ))
            } else {
                Ok(())
            }
        };
        check()?;
        let (cross, input_span, encoder_peak) = pool(|| {
            call("encode formula", || {
                let input_span = tensor::write(&mut self.input, &[1, 3, 768, 768], pixels)? as u64;
                super::check_budget(input_span + 2_654_208, self.native_limit)?;
                let result = fallible("formula encoder", || {
                    self.encoder
                        .prediction_from_features(self.input_provider.as_ref())
                })?;
                let (cross, cross_span) =
                    output(&result, "cross_kv", CROSS, ml::MultiArrayDType::F16)?;
                let (_, hidden_span) =
                    output(&result, "hidden", &[1, 144, 512], ml::MultiArrayDType::F32)?;
                let peak = input_span + cross_span + hidden_span;
                super::check_budget(peak, self.native_limit)?;
                Ok((cross, input_span, peak))
            })
        })?;
        check()?;
        let mut decoding = pool(|| {
            call("initialize decoder state", || {
                self.decoders[0].start(&cross, self.cache_limit)
            })
        })?;
        let mut generated = Generation {
            ids: vec![2],
            native_peak: encoder_peak,
            cache_peak: decoding.span,
            promotions: 0,
        };
        let mut decoder_index = 0;
        let mut logits = vec![0f32; 50000];
        let mut token = [0f32; 512];
        let mut position = [0f32; 512];
        let mut embedding = [0u16; 512];
        for pos in 0..max_tokens {
            check()?;
            if pos == 256 {
                let next = pool(|| {
                    call("promote formula cache", || {
                        let next =
                            self.decoders[1].start(&cross, self.cache_limit - decoding.span)?;
                        let mut old = vec![0u16; 16 * 32 * 256];
                        let mut new = vec![0u16; 16 * 32 * 2048];
                        let mut peak =
                            decoding.span + next.span + (old.len() + new.len()) as u64 * 2;
                        super::check_budget(peak, self.cache_limit)?;
                        for layer in 0..8 {
                            for key in [true, false] {
                                let name = ns::String::with_str(&format!(
                                    "layers_{layer}_{}_cache",
                                    if key { "key" } else { "value" }
                                ));
                                let mut read = Err(invalid("state read callback did not run"));
                                decoding.state.with_multi_array_for_state_named(&name, |a| {
                                    read = tensor::read_half(a, &state_shape(key, 256), &mut old)
                                });
                                let old_span = read?;
                                new.fill(0);
                                let segment = if key { 256 } else { 256 * 32 };
                                let target = if key { 2048 } else { 2048 * 32 };
                                for (source, dest) in
                                    old.chunks_exact(segment).zip(new.chunks_exact_mut(target))
                                {
                                    dest[..segment].copy_from_slice(source);
                                }
                                let mut write = Err(invalid("state write callback did not run"));
                                next.state.with_multi_array_for_state_named(&name, |a| {
                                    write = tensor::write_half(a, &state_shape(key, 2048), &new)
                                });
                                let span = write?;
                                // Charge any larger spans exposed by scoped access as well.
                                peak = peak.max(
                                    decoding.span
                                        + next.span
                                        + (old_span as u64).saturating_sub(old.len() as u64 * 2)
                                        + (span as u64).saturating_sub(new.len() as u64 * 2)
                                        + (old.len() + new.len()) as u64 * 2,
                                );
                                super::check_budget(peak, self.cache_limit)?;
                            }
                        }
                        generated.cache_peak = generated.cache_peak.max(peak);
                        Ok(next)
                    })
                })?;
                decoding = next;
                decoder_index = 1;
                generated.promotions += 1;
            }
            self.tokens.row(
                *generated.ids.last().expect("start token") as usize,
                &mut token,
            )?;
            self.positions.row(pos + 2, &mut position)?;
            for i in 0..512 {
                embedding[i] = f16::from_f32(token[i] + position[i]).to_bits();
            }
            let decoder = &self.decoders[decoder_index];
            decoding.mask_host[..=pos].fill(0);
            decoding.write_host.fill(0);
            decoding.write_host[pos] = f16::ONE.to_bits();
            let next = pool(|| {
                call("decode formula token", || {
                    let shape = &[1, 1, 1, decoder.capacity];
                    let mut used = input_span
                        + Layout::inspect_typed(&cross, CROSS, ml::MultiArrayDType::F16)?.span
                            as u64;
                    used += tensor::write_half(&mut decoding.embedding, &[1, 1, 512], &embedding)?
                        as u64;
                    used +=
                        tensor::write_half(&mut decoding.mask, shape, &decoding.mask_host)? as u64;
                    used +=
                        tensor::write_half(&mut decoding.write_mask, shape, &decoding.write_host)?
                            as u64;
                    super::check_budget(used + 200_000, self.native_limit)?;
                    let result = fallible("formula decoder", || {
                        decoder.model.prediction_from_features_using_state(
                            decoding.provider.as_ref(),
                            &decoding.state,
                        )
                    })?;
                    let (out, span) =
                        output(&result, "logits", &[1, 50000], ml::MultiArrayDType::F32)?;
                    used += span.max(tensor::read(&out, &[1, 50000], &mut logits)? as u64);
                    super::check_budget(used, self.native_limit)?;
                    generated.native_peak = generated.native_peak.max(used);
                    let mut best = 0;
                    for (i, &value) in logits.iter().enumerate() {
                        if !value.is_finite() {
                            return Err(invalid("non-finite formula logits"));
                        }
                        if value > logits[best] {
                            best = i;
                        }
                    }
                    Ok(best as u32)
                })
            })?;
            generated.ids.push(next);
            check()?;
            if next == 2 {
                break;
            }
        }
        Ok(generated)
    }
}
