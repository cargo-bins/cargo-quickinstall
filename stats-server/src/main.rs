use std::net::SocketAddr;
use std::{collections::BTreeMap, sync::LazyLock};

use axum::{
    extract::Query,
    response::Redirect,
    routing::{get, post},
    Router,
};
use influxrs::{InfluxClient, Measurement};
use tokio::net::TcpListener;

static INFLUX_CLIENT: LazyLock<InfluxClient> = LazyLock::new(|| {
    let url = get_env("INFLUX_URL");
    let token = get_env("INFLUX_TOKEN");
    let org = get_env("INFLUX_ORG");
    InfluxClient::builder(url, token, org).build().unwrap()
});

static INFLUX_BUCKET: LazyLock<String> = LazyLock::new(|| get_env("INFLUX_BUCKET"));

fn main() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let task = rt.spawn(async move {
        let app = Router::new()
            .route("/", get(root))
            .route("/record-install", get(redirect_to_root))
            .route("/record-install", post(record_install));

        // Smoke test that we can write to influxdb before listening on the socket.
        // This is a poor man's startup probe to avoid serving traffic before we can write to influxdb.
        INFLUX_CLIENT
            .write(
                &INFLUX_BUCKET,
                &[Measurement::builder("startups")
                    .field("count", 1)
                    .build()
                    .unwrap()],
            )
            .await
            .unwrap();
        // ipv6 + ipv6 any addr
        let addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 0], 8080));
        let listener = TcpListener::bind(addr).await.unwrap();

        axum::serve(listener, app).await.unwrap();
    });
    rt.block_on(task).unwrap();
}

async fn root() -> &'static str {
    "This is the stats server for cargo-quickinstall. Go to https://github.com/cargo-bins/cargo-quickinstall for more information."
}

fn get_env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("{key} must be set"))
}

async fn redirect_to_root() -> Redirect {
    Redirect::to("/")
}

async fn record_install(Query(params): Query<BTreeMap<String, String>>) -> String {
    println!("Hi there {params:?}");

    let mut point = Measurement::builder("counts").field("count", 1);
    for (tag, value) in &params {
        if !["crate", "version", "target", "agent", "status"].contains(&tag.as_str()) {
            println!("Skipping unknown query param: {tag}={value}");
            continue;
        }
        point = point.tag(tag, value.as_str())
    }
    INFLUX_CLIENT
        .write(&INFLUX_BUCKET, &[point.build().unwrap()])
        .await
        .unwrap();
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
