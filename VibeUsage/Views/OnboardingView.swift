import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var apiKey = ""
    @State private var apiUrl = AppConfig.defaultApiUrl
    @State private var showAdvanced = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var runtimeMissing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)

                Text("Vibe Usage")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text("记录你各种工具的 Token 使用量")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.5))
            }
            .padding(.top, 40)
            .padding(.bottom, 32)

            // Runtime check
            if runtimeMissing {
                runtimeWarning
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)
            }

            // Steps
            VStack(alignment: .leading, spacing: 20) {
                stepRow(number: 1, title: "获取 API Key") {
                    Button {
                        if let url = URL(string: "\(apiUrl)/usage/setup") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("打开 \(apiUrl)/usage/setup")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }

                stepRow(number: 2, title: "粘贴 API Key") {
                    TextField("vbu_...", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color(white: 0.09))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.16), lineWidth: 1)
                        )
                }

                // Advanced settings (API URL)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                        Text("高级设置")
                            .font(.caption)
                    }
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.leading, 36)
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API URL")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                            .padding(.leading, 36)

                        TextField(AppConfig.defaultApiUrl, text: $apiUrl)
                            .textFieldStyle(.plain)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color(white: 0.09))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(white: 0.16), lineWidth: 1)
                            )
                            .padding(.leading, 36)

                        Text("本地开发测试时使用 http://localhost:3000")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.38))
                            .padding(.leading, 36)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 36)
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // CTA
            Button {
                Task { await validateAndSave() }
            } label: {
                HStack {
                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    }
                    Text(isValidating ? "验证中..." : "开始使用")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .disabled(apiKey.isEmpty || !apiKey.hasPrefix("vbu_") || isValidating || runtimeMissing)
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 480)
        .background(Color(white: 0.04))
        .onAppear {
            runtimeMissing = RuntimeDetector.detect() == nil

            // If existing config has a custom apiUrl, pre-fill it
            if let config = ConfigManager.load(), let url = config.apiUrl, !url.isEmpty {
                apiUrl = url
                if url != AppConfig.defaultApiUrl {
                    showAdvanced = true
                }
            }
        }
    }

    // MARK: - Subviews

    private func stepRow(number: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 24, height: 24)
                .background(Color(white: 0.09))
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color(white: 0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.white)
                content()
            }
        }
    }

    private var runtimeWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("未检测到 Node.js 或 Bun")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Link("安装 Node.js →", destination: URL(string: "https://nodejs.org")!)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Validation

    private func validateAndSave() async {
        errorMessage = nil
        isValidating = true
        defer { isValidating = false }

        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty, URL(string: trimmedUrl) != nil else {
            errorMessage = "请输入有效的 API URL"
            return
        }

        // Validate key via direct HTTP (fast, no disk writes)
        let client = APIClient(baseURL: trimmedUrl, apiKey: apiKey)

        do {
            let response = try await client.validateKeyAndFetch()
            appState.configure(apiKey: apiKey, apiUrl: trimmedUrl)
            appState.buckets = response.buckets
            appState.hasAnyData = response.hasAnyData
            dismissWindow(id: "onboarding")
        } catch let error as APIClient.APIError {
            if case .unauthorized = error {
                errorMessage = "API Key 无效，请检查后重试"
            } else {
                errorMessage = "网络错误: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = "保存配置失败: \(error.localizedDescription)"
        }
    }
}
