import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            UsagePanel(model: model)
                .tabItem { Label("用量与费用", systemImage: "chart.bar.xaxis") }
            AboutPanel()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 500)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences

    init(model: AppModel) {
        self.model = model
        self.prefs = model.prefs
    }

    private var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeepmacOS", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("增强功能").font(.headline)
                    Toggle("全局快捷键（⌥Space）唤起窗口", isOn: $prefs.globalHotKeyEnabled)
                    Toggle("Services 菜单 / 右键服务「用 DeepSeek 提问」", isOn: $prefs.servicesEnabled)
                    Toggle("菜单栏常驻图标", isOn: $prefs.menuBarEnabled)
                    Text("以上功能默认关闭。关闭状态下不注册任何热键、不响应服务调用、不显示菜单栏图标。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("余额提醒").font(.headline)
                    HStack(spacing: 10) {
                        Text("低余额阈值")
                        TextField("", value: $prefs.lowBalanceThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Picker("", selection: $prefs.thresholdCurrency) {
                            Text("CNY").tag("CNY")
                            Text("USD").tag("USD")
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    Text("默认 10，可自行修改；余额低于该值时通知一次（每天最多一次）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("数据").font(.headline)
                    HStack(spacing: 10) {
                        Button("打开数据目录") {
                            NSWorkspace.shared.open(dataDirectory)
                        }
                        Button("立即刷新余额") {
                            model.refreshBalance(force: true)
                        }
                    }
                    Text("会话历史由官方前端保存在本机 WebView 存储中；用量账本为 usage.jsonl，仅存本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key").font(.headline)
                    Text("在聊天界面的「设置」里填写，由官方前端保存在本机存储，本应用不额外复制。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UsagePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ledger: UsageLedger

    init(model: AppModel) {
        self.model = model
        self.ledger = model.ledger
    }

    private func money(_ value: Double) -> String {
        if value >= 1 { return String(format: "$%.2f", value) }
        if value >= 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.6f", value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                balanceCard
                statsCard
                weekCard
                recentCard
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshBalance() }
    }

    private var balanceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("账户余额").font(.headline)
                    Spacer()
                    if model.balanceLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button("刷新") { model.refreshBalance(force: true) }
                        .controlSize(.small)
                }
                if model.balanceAvailable == false {
                    Label("余额不足，后续请求会被拒绝", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if model.balance.isEmpty {
                    Text(model.balanceError ?? "暂无余额数据")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.balance) { info in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(info.symbol)\(String(format: "%.2f", info.total))")
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                            Text(info.currency)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("充值 \(String(format: "%.2f", info.toppedUp)) · 赠送 \(String(format: "%.2f", info.granted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let updated = model.balanceUpdatedAt {
                    Text("上次更新 \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("用量与花费").font(.headline)
                    Spacer()
                    Text("按官方价目本地估算（USD），peak 时段双倍")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: 22) {
                    stat("今日", money(ledger.todayCost))
                    stat("本月", money(ledger.monthCost))
                    stat("本月搜索", "\(ledger.monthSearches) 次")
                    stat("今日 Token", "\(ledger.todayTokens.input) 入 / \(ledger.todayTokens.output) 出")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium, design: .rounded))
        }
    }

    private var weekCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("最近 7 天").font(.headline)
                let days = ledger.lastSevenDays
                let peak = max(days.map(\.cost).max() ?? 0, 0.000001)
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, entry in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.gradient)
                                .frame(width: 26, height: max(3, CGFloat(entry.cost / peak) * 70))
                            Text(entry.day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 90, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近请求").font(.headline)
                if ledger.recent.isEmpty {
                    Text("还没有记录。发送一条消息后这里会出现用量。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ledger.recent) { record in
                        HStack(spacing: 8) {
                            Text(Date(timeIntervalSince1970: record.t).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text(record.model)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text("\(record.input + record.cacheWrite + record.cacheRead + record.output) tok")
                                .font(.caption)
                            if record.searches > 0 {
                                Text("搜索 \(record.searches)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(Pricing.cost(record)))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AboutPanel: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("DeepmacOS \(version)").font(.title2.weight(.semibold))
                Text("第三方 macOS 客户端：原生壳 + 官方开源聊天前端（chat-demo）+ DeepSeek 官方 API。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("界面来自 deepseek-ai/chat-demo（MIT），本应用只做原生壳、本地服务与系统集成，不修改其界面行为。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("与 DeepSeek 官方无隶属关系；使用你自己的 API Key，按官方价目计费。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 12) {
                    Link("chat-demo", destination: URL(string: "https://github.com/deepseek-ai/chat-demo")!)
                    Link("API 文档", destination: URL(string: "https://api-docs.deepseek.com/")!)
                    Link("问题反馈", destination: URL(string: "https://github.com/deepseek-ai/chat-demo/issues")!)
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
