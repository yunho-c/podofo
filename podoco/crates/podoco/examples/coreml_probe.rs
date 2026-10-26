//! Development-only dynamic-library probe for the selected Core ML dependency.
//!
//! This is not part of Podoco's public C ABI or document-analysis implementation.

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple {
    use cidre::{ml, ml::FeatureProvider, ns, objc};
    use std::{ffi::CStr, os::raw::c_char};

    fn predict(path: &str) {
        objc::ar_pool(|| {
            ns::try_catch(|| {
                let url = ns::Url::with_fs_path_str(path, true);
                let mut config = ml::ModelCfg::new();
                config.set_compute_units(ml::ComputeUnits::Cpu);
                let model = ml::Model::with_cfg(&url, &config).expect("load affine fixture");
                let shape = ns::Array::from_slice_retained(&[
                    ns::Number::with_i32(1),
                    ns::Number::with_i32(2),
                    ns::Number::with_i32(3),
                ]);
                let mut input = ml::MultiArray::with_shape(&shape, ml::MultiArrayDType::F32)
                    .expect("allocate input");
                let values = [-3.0, -1.0, 0.0, 0.5, 1.0, 3.0];
                for (index, value) in values.iter().enumerate() {
                    input.set(&ns::Number::with_f32(*value), index as isize);
                }
                let mut dictionary = ns::DictionaryMut::<ns::String, ns::Id>::with_capacity(1);
                let value = ml::FeatureValue::with_multi_array(&input);
                dictionary.insert(&ns::String::with_str("x"), value.as_id_ref());
                let provider = ml::DictionaryFeatureProvider::with_dictionary(&dictionary)
                    .expect("create input provider");
                // Reuse the model/provider and check both outputs on every prediction.
                for _ in 0..3 {
                    let result = model
                        .prediction_from_features(provider.as_ref())
                        .expect("predict");
                    for (name, scale, bias) in [("y", 2.0, 1.0), ("z", 3.0, -1.0)] {
                        let output = result
                            .feature_value_for_name(&ns::String::with_str(name))
                            .expect("output feature")
                            .multi_array()
                            .expect("output array");
                        assert_eq!(output.count(), 6);
                        for (index, value) in values.iter().enumerate() {
                            assert_eq!(output.get(index as isize).as_f32(), value * scale + bias);
                        }
                    }
                }
            })
            .expect("Core ML must not throw an Objective-C exception");
        });
    }

    /// Run three CPU-only predictions. Returns zero on success, one on failure.
    ///
    /// # Safety
    /// `path` must point to a live, NUL-terminated UTF-8 path for the whole call.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn podoco_coreml_probe(path: *const c_char) -> i32 {
        if path.is_null() {
            return 1;
        }
        let result = std::panic::catch_unwind(|| {
            // SAFETY: The development runner owns the NUL-terminated buffer for this call.
            let path = unsafe { CStr::from_ptr(path) }
                .to_str()
                .expect("UTF-8 path");
            predict(path);
        });
        i32::from(result.is_err())
    }
}
