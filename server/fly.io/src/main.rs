use axum::{
    extract::Query,
    routing::{get, post},
    Router,
};
use std::collections::HashMap;
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/", get(root))
        .route("/record-install", get(record_install))
        .route("/record-install", post(record_install));

    // ipv6 + ipv6 any addr
    let addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 0], 8080));
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}

async fn root() -> &'static str {
    "Hello, World!"
}

async fn record_install(Query(params): Query<HashMap<String, String>>) -> String {
    format!("Hi there {params:?}")
}
