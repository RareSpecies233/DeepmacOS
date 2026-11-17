import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            if model.serverURL != nil {
                WebViewContainer(model: model)
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(model.serverError ?? "正在启动本地服务…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.findBarVisible {
                FindBar(model: model)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

struct FindBar: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("在页面中查找", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .frame(width: 220)
                .onSubmit { model.findNext() }
            Button("下一个") { model.findNext() }
                .keyboardShortcut(.defaultAction)
            Button("关闭") { model.findBarVisible = false }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(radius: 10, y: 2)
        .onAppear { focused = true }
    }
}
