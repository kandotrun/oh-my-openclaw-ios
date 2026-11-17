import SwiftUI
import OhMyOpenClawCore

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var urlText = ""
    @State private var secret = ""
    @State private var password = false
    @State private var setupCode = ""
    @State private var useSetupCode = false
    @State private var showScanner = false

    private var isConnecting: Bool { model.connectionState == .connecting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    AgentAvatar(size: 64)
                    Text("Oh My\nOpenClaw")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .tracking(-0.8)
                        .accessibilityLabel("Oh My OpenClaw")
                    Text("あなたのエージェントと、\n会話の続きへ。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 18) {
                    Picker("接続方法", selection: $useSetupCode) {
                        Text("接続情報").tag(false)
                        Text("セットアップコード").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if useSetupCode {
                        VStack(alignment: .leading, spacing: 10) {
                            SecureField("セットアップコードを貼り付け", text: $setupCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(15)
                                .background(ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("setupCodeField")
                            Button { showScanner = true } label: {
                                Label("QR を読み取る", systemImage: "qrcode.viewfinder")
                            }
                            .chatGlassButton()
                            .buttonBorderShape(.capsule)
                            .frame(minHeight: 44)
                            Text("接続後、Gateway 側で端末の承認が必要です。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Gateway URL").font(.subheadline.weight(.medium))
                            TextField("wss://gateway.example.com", text: $urlText)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.URL)
                                .padding(15)
                                .background(ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("connectionURL")
                            HStack {
                                Text(password ? "パスワード" : "Gateway トークン").font(.subheadline.weight(.medium))
                                Spacer()
                                Menu {
                                    Button("トークンを使う") { password = false }
                                    Button("パスワードを使う") { password = true }
                                } label: {
                                    Label("変更", systemImage: "chevron.down").font(.caption)
                                }
                                .chatGlassButton()
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                            }
                            SecureField(password ? "パスワード" : "トークン", text: $secret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(15)
                                .background(ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("connectionSecret")
                        }
                    }

                    Button {
                        Task { await model.connect(urlText: urlText, secret: secret, password: password, setupCode: useSetupCode ? setupCode : "") }
                    } label: {
                        HStack(spacing: 10) {
                            if isConnecting { ProgressView().tint(.white) }
                            Text(isConnecting ? "接続中…" : "Gateway に接続")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .chatGlassButton(prominent: true)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(isConnecting || (useSetupCode ? setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("connectButton")

                    connectionFeedback
                }

                VStack(spacing: 12) {
                    Button { Task { await model.startDemo() } } label: {
                        Text("デモを試す")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .chatGlassButton()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("demoButton")
                    Text("デモはサンプルの会話です。Gateway や AI には接続しません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text("接続情報はこの端末の Keychain に保存します。通常の接続には TLS で保護された wss:// URL を使ってください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 500, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ChatTheme.canvas)
        .tint(ChatTheme.accent)
        .sheet(isPresented: $showScanner) { QRScannerView { setupCode = $0 } }
    }

    @ViewBuilder
    private var connectionFeedback: some View {
        switch model.connectionState {
        case .pairing(let requestID, let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Gateway でこの端末を承認してください", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                Text(message).font(.footnote)
                if !requestID.isEmpty {
                    Text("openclaw devices approve \(requestID)")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("承認後に再接続") { Task { await model.retryConnection() } }
                        .chatGlassButton()
                        .buttonBorderShape(.capsule)
                        .frame(minHeight: 44)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 16))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
