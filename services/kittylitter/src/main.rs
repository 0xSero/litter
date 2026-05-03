fn main() -> anyhow::Result<()> {
    alleycat::App {
        binary_name: "kittylitter",
        qualifier: "com",
        organization: "sigkitten",
        application: "kittylitter",
        label: "com.sigkitten.kittylitter",
    }
    .run()
}
