/// Build version, stamped at build time by Scripts/build.sh (commit hash + dirty flag + time).
/// The committed value is "dev"; build via `Scripts/build.sh` to bake in the real commit so the
/// running binary's version is logged and shown in the Control Panel — no more guessing which
/// build is live. A bare `swift build` leaves it "dev".
enum BuildInfo {
    static let version = "dev"
}
