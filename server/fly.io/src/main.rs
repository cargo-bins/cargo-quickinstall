use std::collections::BTreeMap;
use std::net::SocketAddr;

use axum::{
    extract::Query,
    routing::{get, post},
    Router,
};
use chrono::Utc;
use influxdb::{Client, InfluxDbWriteable, Query as _, ReadQuery, Timestamp, WriteQuery};

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

fn get_env(key: &str) -> String {
    std::env::var(key).expect(&format!("{key} must be set"))
}

async fn record_install(Query(params): Query<BTreeMap<String, String>>) -> String {
    println!("Hi there {params:?}");

    // FIXME: make this in main and pass it down or something?
    let url = get_env("INFLUX_URL");
    let bucket = get_env("INFLUX_BUCKET");
    let org = get_env("INFLUX_ORG");
    let token = get_env("INFLUX_TOKEN");
    let client = Client::new(url, bucket).with_token(token);

    let mut point = Timestamp::from(Utc::now())
        .into_query("counts")
        .add_field("count", 1);
    for (tag, value) in &params {
        point = point.add_tag(tag, &**value)
    }
    client.query(point).await.unwrap();
    format!("Hi there {params:?}")
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use axum::extract::Query;

    use crate::record_install;

    #[tokio::test]
    async fn smoke_test_against_real_server() {
        if std::env::var("INFLUX_TOKEN").is_err() {
            println!("set INFLUX_URL, INFLUX_ORG and INFLUX_TOKEN to enable this test");
            return;
        }
        record_install(Query(
            [("x".to_string(), "y".to_string())]
                .into_iter()
                .collect::<BTreeMap<String, String>>(),
        ))
        .await;
    }
}
