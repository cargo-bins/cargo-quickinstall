extern crate cfg_if;
extern crate wasm_bindgen;

mod utils;

use cfg_if::cfg_if;
use wasm_bindgen::prelude::*;

cfg_if! {
    // When the `wee_alloc` feature is enabled, use `wee_alloc` as the global
    // allocator.
    if #[cfg(feature = "wee_alloc")] {
        extern crate wee_alloc;
        #[global_allocator]
        static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;
    }
}

// For some reason, rustfmt removes the `async` keyword here.
#[rustfmt::skip]
#[wasm_bindgen]
extern "C" {
    type KV;

    #[wasm_bindgen(static_method_of = KV)]
    async fn get(key: &str) -> JsValue;

    #[wasm_bindgen(static_method_of = KV)]
    async fn put(key: &str, val: &str) -> JsValue;

    #[wasm_bindgen(static_method_of = KV)]
    async fn delete(key: &str) -> JsValue;
}

#[wasm_bindgen]
pub async fn greet() -> String {
    format!(
        "Hello, wasm-worker! from KV: {}",
        KV::get("key-0").await.as_string().unwrap_or("".to_string())
    )
}
