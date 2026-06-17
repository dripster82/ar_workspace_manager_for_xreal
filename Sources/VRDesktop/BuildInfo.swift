/// Build identity, stamped at build time by Scripts/build.sh (commit hash + dirty flag + date).
/// The committed values are placeholders; build via `Scripts/build.sh` to bake in the real commit
/// so the running binary's build is logged and shown in the Control Panel status bar. A bare
/// `swift build` leaves these as "dev".
enum BuildInfo {
    static let commit = "dev"
    static let date = "—"
    static let version = "dev"
}
