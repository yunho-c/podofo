//! Native objects stay on their creating thread. Patterns adapted from MLSR's
//! Apache-2.0 runtime/coreml at the source revision recorded in M2 validation.
mod tensor;

use crate::{Error, ErrorCode, ModelBundle, Result, options::ComputePolicy};
use cidre::{arc, ml, ml::FeatureProvider, ns, objc};
use std::{marker::PhantomData, rc::Rc};
use tensor::{Layout, read, write};

pub(crate) fn pool<T: 'static>(f: impl FnOnce() -> T) -> T {
    let mut value = None;
    objc::ar_pool(|| value = Some(f()));
    value.expect("autorelease closure completed")
}

fn native_error(operation: &str, error: ns::ExErr<'_>) -> Error {
    let message = match error {
        ns::ExErr::Err(e) => {
            let domain = e.domain().to_string();
            format!(
                "{operation}: {domain} ({}): {}",
                e.code(),
                e.localized_desc()
            )
        }
        ns::ExErr::Ex(e) => {
            let name = e.name().to_string();
            format!("{operation}: {name}: {e}")
        }
    };
    Error::new(ErrorCode::Backend, message)
}
fn call<T>(operation: &str, f: impl FnOnce() -> Result<T>) -> Result<T> {
    ns::try_catch(f).map_err(|e| native_error(operation, e.into()))?
}
fn fallible<'a, T>(operation: &str, f: impl FnOnce() -> ns::Result<'a, T>) -> Result<T> {
    ns::try_catch_err(f).map_err(|e| native_error(operation, e))
}
fn invalid(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::Backend, message)
}

pub(crate) struct LayoutModel {
    model: arc::R<ml::Model>,
    input: arc::R<ml::MultiArray>,
    provider: arc::R<ml::DictionaryFeatureProvider>,
    native_budget: u64,
    input_span: u64,
    _thread: PhantomData<Rc<()>>,
    #[cfg(test)]
    pub(crate) scan_masks: bool,
}
impl LayoutModel {
    pub(crate) fn input_span(&self) -> u64 {
        self.input_span
    }
    pub(crate) fn load(
        bundle: &ModelBundle,
        policy: ComputePolicy,
        native_budget: u64,
    ) -> Result<Self> {
        pool(|| {
            call("load layout model", || {
                let path = bundle
                    .directory()
                    .join(&bundle.manifest().artifacts["compiled"].path);
                let path = path.to_str().ok_or_else(|| {
                    Error::new(ErrorCode::InvalidAsset, "Core ML path is not UTF-8")
                })?;
                let url = ns::Url::with_fs_path_str(path, true);
                let mut config = ml::ModelCfg::new();
                config.set_compute_units(match policy {
                    ComputePolicy::CpuOnly => ml::ComputeUnits::Cpu,
                    ComputePolicy::CpuAndNeuralEngine => ml::ComputeUnits::CpuNe,
                    ComputePolicy::All => ml::ComputeUnits::All,
                });
                let model = fallible("load compiled model", || ml::Model::with_cfg(&url, &config))?;
                let desc = model.model_desc();
                for (features, specs) in [
                    (
                        desc.input_descs_by_name(),
                        std::slice::from_ref(&bundle.manifest().profile.input),
                    ),
                    (
                        desc.output_descs_by_name(),
                        bundle.manifest().profile.outputs.as_slice(),
                    ),
                ] {
                    if features.len() != specs.len() {
                        return Err(invalid("unexpected native feature count"));
                    }
                    for spec in specs {
                        let feature = features
                            .get(&ns::String::with_str(&spec.name))
                            .ok_or_else(|| invalid(format!("missing feature {}", spec.name)))?;
                        let constraint = feature
                            .multi_array_constraint()
                            .ok_or_else(|| invalid("feature is not a tensor"))?;
                        let shape: Vec<i64> =
                            constraint.shape().iter().map(|n| n.as_i64()).collect();
                        if constraint.data_type() != ml::MultiArrayDType::F32
                            || shape != spec.shape.iter().map(|&n| i64::from(n)).collect::<Vec<_>>()
                            || feature.is_optional()
                        {
                            return Err(invalid(format!(
                                "incompatible native contract: {}",
                                spec.name
                            )));
                        }
                    }
                }
                let shape = ns::arr![1, 3, 800, 800];
                let input = fallible("allocate layout input", || {
                    ml::MultiArray::with_shape(shape, ml::MultiArrayDType::F32)
                })?;
                let input_span = Layout::inspect(&input, &[1, 3, 800, 800])?.span as u64;
                check_budget(input_span + 48_394_800, native_budget)?;
                let mut dictionary = ns::DictionaryMut::<ns::String, ns::Id>::with_capacity(1);
                dictionary.insert(
                    &ns::String::with_str("pixel_values"),
                    ml::FeatureValue::with_multi_array(&input).as_id_ref(),
                );
                let provider = fallible("create layout provider", || {
                    ml::DictionaryFeatureProvider::with_dictionary(&dictionary)
                })?;
                Ok(Self {
                    model,
                    input,
                    provider,
                    native_budget,
                    input_span,
                    _thread: PhantomData,
                    #[cfg(test)]
                    scan_masks: false,
                })
            })
        })
    }

    /// Only the three small outputs are mapped to CPU memory. Mask metadata is
    /// checked and charged without reading or copying its contents.
    pub(crate) fn predict(
        &mut self,
        input: &[f32],
        logits: &mut [f32],
        boxes: &mut [f32],
        order: &mut [f32],
    ) -> Result<u64> {
        pool(|| {
            call("layout prediction", || {
                // Core ML may report updated strides during scoped access.
                // Charge that span, not an earlier metadata-only observation.
                self.input_span =
                    self.input_span
                        .max(write(&mut self.input, &[1, 3, 800, 800], input)? as u64);
                check_budget(self.input_span + 48_394_800, self.native_budget)?;
                let result = fallible("predict layout", || {
                    self.model.prediction_from_features(self.provider.as_ref())
                })?;
                let mut used = self.input_span;
                for (name, shape, destination) in [
                    ("logits", &[1, 300, 25][..], Some(logits)),
                    ("pred_boxes", &[1, 300, 4][..], Some(boxes)),
                    ("order_logits", &[1, 300, 300][..], Some(order)),
                    ("out_masks", &[1, 300, 200, 200][..], None),
                ] {
                    let value = result
                        .feature_value_for_name(&ns::String::with_str(name))
                        .ok_or_else(|| invalid(format!("missing output {name}")))?;
                    let array = value
                        .multi_array()
                        .ok_or_else(|| invalid("output is not a tensor"))?;
                    let layout = Layout::inspect(&array, shape)?;
                    let mut span = layout.span;
                    if let Some(destination) = destination {
                        span = span.max(read(&array, shape, destination)?);
                    }
                    #[cfg(test)]
                    if name == "out_masks" && self.scan_masks {
                        span = span.max(tensor::check_finite(&array, shape)?);
                    }
                    used = used
                        .checked_add(span as u64)
                        .ok_or_else(|| invalid("native allocation overflow"))?;
                    check_budget(used, self.native_budget)?;
                }
                Ok(used)
            })
        })
    }
}
fn check_budget(bytes: u64, limit: u64) -> Result<()> {
    if bytes > limit {
        Err(Error::new(
            ErrorCode::LimitExceeded,
            "native tensor spans exceed budget",
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exception_diagnostic_survives_pool_release() {
        let error = pool(|| {
            call::<()>("deliberate test", || {
                ns::Exception::raise(&ns::String::with_str("podoco scoped exception test"));
            })
        })
        .unwrap_err();
        assert_eq!(error.code, ErrorCode::Backend);
        assert!(error.message.contains("podoco scoped exception test"));
    }
    #[test]
    fn strided_native_roundtrip_ignores_padding_and_supports_broadcast_reads() {
        pool(|| {
            call("strided tensor test", || {
                let shape = ns::arr![2, 3];
                let mut array =
                    ml::MultiArray::with_strides(&shape, ml::MultiArrayDType::F32, &ns::arr![4, 1]);
                write(&mut array, &[2, 3], &[1., 2., 3., 4., 5., 6.])?;
                let mut output = [0.; 6];
                read(&array, &[2, 3], &mut output)?;
                assert_eq!(output, [1., 2., 3., 4., 5., 6.]);
                let mut backing = [7.0f32, 0., 0., 8., 0., 0.];
                // SAFETY: Initialized backing covers the declared strides and
                // stays exclusively borrowed until the array is dropped below.
                // No native deallocator runs for this caller-owned stack buffer.
                let mut broadcast = unsafe {
                    ml::MultiArray::with_ptr(
                        backing.as_mut_ptr().cast(),
                        &shape,
                        ml::MultiArrayDType::F32,
                        &ns::arr![3, 0],
                        None,
                    )
                }
                .map_err(|e| native_error("test broadcast", e.into()))?;
                assert!(write(&mut broadcast, &[2, 3], &output).is_err());
                read(&broadcast, &[2, 3], &mut output)?;
                assert_eq!(output, [7., 7., 7., 8., 8., 8.]);
                drop(broadcast);
                Ok(())
            })
            .unwrap();
        });
    }
}
