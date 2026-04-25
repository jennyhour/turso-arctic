#[cfg(feature = "mvcc-original-index")]
include!("cursor_original.rs");

#[cfg(not(feature = "mvcc-original-index"))]
include!("cursor_arctic.rs");
