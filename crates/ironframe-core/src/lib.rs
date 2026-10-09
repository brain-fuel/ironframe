//! Ironframe's library: the manifest and its checks, resolving an environment, the compose file
//! and OpenTofu root generated from it, the podman and OpenTofu drivers, configuration sync, and
//! the environment attestation. The `ironframe` binary and the configuration service are thin
//! layers over it. Ironframe only wires: it holds no contract and knows nothing of what a twin does
//! inside. ref:DEC-three-planes ref:DEC-wiring-in-ironframe

pub mod attest;
pub mod compose;
pub mod manifest;
pub mod ops;
pub mod podman;
pub mod process;
pub mod settings;
pub mod sync;
pub mod tofu;
pub mod workdir;
