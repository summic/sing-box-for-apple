import Library
import SwiftUI

//
//  Select Profile —— 严格按服务端 API 的 groups 分组渲染。
//  数据源只有一处：KNLink.fetchConfigList() → groups.rule[] / groups.global[]。
//  绝不读取「当前加载配置内部的出口节点」(那是 sing-box 另一层，不在这里显示)。
//  每一项 = 一份配置文件 = 一个可选 profile；选中即写入 knlinkSelectedConfigID，连接时用它。
//

public struct KNLinkConfigListView: View {
    @State private var rule: [KNLink.ConfigItem] = []
    @State private var global: [KNLink.ConfigItem] = []
    @State private var matched: String?
    @State private var selected = ""
    @State private var loading = true
    @State private var error: String?

    public init() {}

    public var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            } else if let error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }
                }.frame(maxWidth: .infinity, alignment: .center)
            } else {
                List {
                    group("规则模式", rule, isRule: true)   // groups.rule —— 就这几条
                    group("全局模式", global, isRule: false) // groups.global —— 就这几条
                }
            }
        }
        .navigationTitle("选择配置")
        .task { await load() }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [KNLink.ConfigItem], isRule: Bool) -> some View {
        if !items.isEmpty {
            Section("\(title)（\(items.count)）") {
                ForEach(items) { c in
                    Button { pick(c.id) } label: {
                        HStack(spacing: 12) {
                            Image("flag-\(c.cc)").resizable().frame(width: 26, height: 26).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(c.name).foregroundStyle(.primary)
                                    if isRule, c.id == matched {
                                        Text("当前地区").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint)
                                    }
                                }
                                Text("出口 \(c.serverName ?? "—")\(isRule ? "" : " · 全部走代理")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.id == selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pick(_ id: String) {
        selected = id
        Task { await SharedPreferences.knlinkSelectedConfigID.set(id) }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let g = try await KNLink.fetchConfigList()
            let sel = await SharedPreferences.knlinkSelectedConfigID.get()
            await MainActor.run {
                rule = g.rule; global = g.global; matched = g.matchedConfigId
                selected = sel.isEmpty ? (g.matchedConfigId ?? "") : sel
                loading = false
            }
        } catch {
            await MainActor.run { self.error = "\(error)"; loading = false }
        }
    }
}
