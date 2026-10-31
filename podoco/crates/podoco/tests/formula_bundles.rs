//! Formula bundle rejection paths need no native runtime or model downloads.
use podoco::{
    ErrorCode,
    domain::Sha256Digest,
    formula::{
        FormulaBundle,
        bundle::{PP_FORMULANET_CONTRACT, PROFILE},
    },
};
use serde_json::json;

#[test]
fn formula_manifest_rejects_contract_drift_unsafe_duplicate_and_missing_payloads() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join(podoco::bundle::MANIFEST_NAME);
    let baseline = json!({"schema_version":1,"id":"pp-formulanet-plus-l-coreml-v1","profile":PROFILE,"qualification":"experimental",
        "contract_sha256":Sha256Digest::of_bytes(PP_FORMULANET_CONTRACT.as_bytes()),"compilation":{},"files":[]});
    let check = |value: serde_json::Value| {
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(
            FormulaBundle::verify(directory.path()).unwrap_err().code,
            ErrorCode::InvalidManifest
        );
    };
    check(baseline.clone());
    let mut drift = baseline.clone();
    drift["profile"] = json!("unqualified");
    check(drift);
    let mut traversal = baseline.clone();
    traversal["files"] = json!([{"path":"../escape","size_bytes":0,"sha256":"0".repeat(64)}]);
    check(traversal);
    let mut duplicate = baseline.clone();
    let entry = json!({"path":"compiled/encoder.mlmodelc/coremldata.bin","size_bytes":0,"sha256":"0".repeat(64)});
    duplicate["files"] = json!([entry, entry]);
    check(duplicate);
    let mut changed = baseline;
    changed["files"] =
        json!([{"path":"checkpoint/tokenizer.json","size_bytes":2140014,"sha256":"0".repeat(64)}]);
    check(changed);
    std::fs::write(&path, "schema_version: 1\nschema_version: 1\n").unwrap();
    assert_eq!(
        FormulaBundle::verify(directory.path()).unwrap_err().code,
        ErrorCode::InvalidManifest
    );
}
