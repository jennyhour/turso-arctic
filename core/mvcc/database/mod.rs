#[cfg(feature = "mvcc-original-index")]
include!("original_impl.rs");

#[cfg(not(feature = "mvcc-original-index"))]
include!("arctic_impl.rs");
