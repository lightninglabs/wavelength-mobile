import SwiftUI
import WalletKit

// ContentView drives the embedded wallet through WalletKit's WalletClient
// (async/throws + AsyncThrowingStream). It boots on signet, creates a wallet,
// polls readiness as the chain syncs, and streams live activity. It mirrors the
// Android sample so the two platforms exercise the same wrapper surface.
struct ContentView: View {
    @State private var client = WalletClient()
    @State private var log = "Tap Start to boot the embedded wallet.\n"
    @State private var running = false
    @State private var busy = false
    @State private var walletReady = false

    private var dataDir: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("wavewalletdk").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("wavewalletdk signet demo").font(.system(.headline, design: .monospaced))

            HStack {
                Button("Start") { start() }.disabled(running || busy)
                Button("Create Wallet") { createWallet() }.disabled(!running || walletReady)
                Button("Balance") { showBalance() }.disabled(!running)
                Button("Stop") { stop() }.disabled(!running)
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .task {
            // Headless driver for CLI / CI runs: set WAVEWALLETDK_AUTOSTART to boot
            // and create a wallet without tapping (the simulator has no CLI tap).
            if ProcessInfo.processInfo.environment["WAVEWALLETDK_AUTOSTART"] != nil {
                await autoStart()
            }
        }
    }

    private func autoStart() async {
        busy = true
        append("Auto-start (signet)…")
        do {
            try await client.start(.signet(dataDir: dataDir))
            running = true
            append("gRPC serving. Creating wallet…")
            pollSync()
            let res = try await client.createWallet(
                walletPassword: Data("wavelength-mobile-demo-password".utf8)
            )
            walletReady = true
            append("wallet created; identity=\(res.identityPubKey.prefix(16))…")
            streamActivity()
        } catch {
            append("autostart failed: \(error)")
        }
        busy = false
    }

    @MainActor private func append(_ line: String) { log += line + "\n" }

    private func start() {
        busy = true
        append("Starting embedded daemon (signet)…")
        Task {
            do {
                try await client.start(.signet(dataDir: dataDir))
                running = true
                append("gRPC serving. Create a wallet to sync.")
                pollSync()
            } catch {
                append("Start failed: \(error)")
            }
            busy = false
        }
    }

    private func createWallet() {
        append("Creating wallet…")
        Task {
            do {
                let res = try await client.createWallet(
                    walletPassword: Data("wavelength-mobile-demo-password".utf8)
                )
                walletReady = true
                append("wallet created; identity=\(res.identityPubKey.prefix(16))…")
                append("seed words: \(res.mnemonic.count); now syncing from Esplora.")
                streamActivity()
            } catch {
                append("createWallet failed: \(error)")
            }
        }
    }

    private func showBalance() {
        Task {
            do {
                let b = try await client.balance()
                append("balance: confirmed=\(b.confirmedSat) pendingIn=\(b.pendingInSat)")
            } catch {
                append("balance failed: \(error)")
            }
        }
    }

    private func stop() {
        Task {
            do {
                try await client.stop()
                running = false
                walletReady = false
                append("Stopped.")
            } catch {
                append("stop failed: \(error)")
            }
        }
    }

    // Poll readiness every 5s while running so the block height and operator
    // connection are visible as the wallet syncs.
    private func pollSync() {
        Task {
            while running {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let info = try? await client.getInfo() {
                    append(
                        "sync: height=\(info.blockHeight) state=\(info.walletState) " +
                        "operator=\(info.serverConnected ? "connected" : "…")"
                    )
                }
            }
        }
    }

    // Stream live activity entries through the AsyncThrowingStream.
    private func streamActivity() {
        Task {
            do {
                for try await e in client.activity(includeExisting: true) {
                    append("activity: \(e.kind) \(e.amountSat)sat \(e.status)")
                }
            } catch {
                append("activity stream ended: \(error)")
            }
        }
    }
}
