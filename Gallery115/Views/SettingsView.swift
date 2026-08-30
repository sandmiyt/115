import SwiftUI

struct SettingsView: View {
  var body: some View {
    List {
      Section {
        NavigationLink {
          MediaSourceSettingsView()
        } label: {
          SettingsCategoryRow(
            title: "媒体源",
            subtitle: "连接状态、检查连接与更换挂载",
            systemName: "externaldrive.fill"
          )
        }

        NavigationLink {
          AppearanceSettingsView()
        } label: {
          SettingsCategoryRow(
            title: "外观",
            subtitle: "主题、资料库布局与封面显示",
            systemName: "paintbrush.fill"
          )
        }

        NavigationLink {
          PlaybackSettingsView()
        } label: {
          SettingsCategoryRow(
            title: "播放",
            subtitle: "字幕、章节、片头片尾、预览与网络恢复",
            systemName: "play.rectangle.fill"
          )
        }

        NavigationLink {
          PrivacySettingsView()
        } label: {
          SettingsCategoryRow(
            title: "隐私",
            subtitle: "面容 ID / 生物识别与后台隐私保护",
            systemName: "lock.shield.fill"
          )
        }

        NavigationLink {
          CacheSettingsView()
        } label: {
          SettingsCategoryRow(
            title: "缓存",
            subtitle: "资料库、封面与最近播放记录",
            systemName: "externaldrive.badge.timemachine"
          )
        }

        NavigationLink {
          AboutSettingsView()
        } label: {
          SettingsCategoryRow(
            title: "关于",
            subtitle: "Cineva 版本与媒体协议信息",
            systemName: "info.circle.fill"
          )
        }
      }
    }
    .navigationTitle("设置")
  }
}

private struct SettingsCategoryRow: View {
  let title: String
  let subtitle: String
  let systemName: String

  var body: some View {
    HStack(spacing: 13) {
      Image(systemName: systemName)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 30, height: 30)
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body.weight(.semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(.vertical, 3)
    }
  }
}

private struct MediaSourceSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var statusMessage: String?
  @State private var isCheckingConnection = false
  @State private var showDisconnectConfirmation = false
  @State private var showMediaSetup = false

  var body: some View {
    Form {
      Section("连接") {
        connectionSummary

        if appState.isConfigured {
          Button(action: checkConnection) {
            HStack {
              Label("检查连接", systemImage: "wave.3.right.circle")
              Spacer()
              if isCheckingConnection { ProgressView() }
            }
          }
          .disabled(isCheckingConnection)

          Button {
            showMediaSetup = true
          } label: {
            Label("更换媒体源", systemImage: "externaldrive.badge.plus")
          }

          Button("断开媒体源", role: .destructive) {
            showDisconnectConfirmation = true
          }
        } else {
          Button {
            showMediaSetup = true
          } label: {
            Label("添加媒体源", systemImage: "externaldrive.badge.plus")
          }
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(statusMessage.contains("正常") ? .green : .secondary)
        }
      }
    }
    .navigationTitle("媒体源")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showMediaSetup) {
      SetupView()
    }
    .onChange(of: appState.isAppUnlocked) { _, unlocked in
      if !unlocked {
        showMediaSetup = false
        showDisconnectConfirmation = false
      }
    }
    .confirmationDialog("断开当前媒体源？", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
      Button("断开媒体源", role: .destructive) {
        appState.signOut()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(disconnectMessage)
    }
  }

  @ViewBuilder
  private var connectionSummary: some View {
    if appState.isConfigured, appState.mediaSourceKind == .cloud115 {
      HStack(spacing: 11) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)

        VStack(alignment: .leading, spacing: 3) {
          Text("115 网盘已连接")
            .font(.subheadline.weight(.semibold))
          Text("通过 115 官方开放平台读取媒体")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      LabeledContent("读取方式", value: "115 Open API")
      Text("登录令牌保存在本机钥匙串，设置页不会显示任何凭据。")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if appState.isConfigured,
      let configuration = WebDAVCredentialStore.shared.configuration
    {
      HStack(spacing: 11) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)

        VStack(alignment: .leading, spacing: 3) {
          Text("OpenList / AList 已连接")
            .font(.subheadline.weight(.semibold))
          Text("媒体库：\(configuration.normalizedRootPath)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      LabeledContent("读取方式", value: "WebDAV 只读")
      if configuration.normalizedWebDAVURL?.scheme?.lowercased() == "http" {
        Label(
          "当前连接使用 HTTP。若要使用 HTTPS，必须先在 OpenList 所在服务器或反向代理真正配置 TLS 和有效证书；仅把 http 改成 https 会直接导致 TLS 连接失败。使用 IP+端口时，证书还必须与该访问地址匹配。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
      Text("服务器地址与账号信息不会在设置页展示。")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Label("未连接媒体源，可在进入软件后自行挂载。", systemImage: "externaldrive.badge.xmark")
        .foregroundStyle(.secondary)
    }
  }

  private var disconnectMessage: String {
    switch appState.mediaSourceKind {
    case .cloud115:
      return "只会移除 Cineva 保存在本机钥匙串中的 115 授权，不会删除网盘里的任何文件。"
    case .webDAV:
      return "只会移除 Cineva 保存的 WebDAV 登录信息，不会删除 OpenList 中挂载的任何文件。"
    }
  }

  private func checkConnection() {
    guard !isCheckingConnection else { return }
    isCheckingConnection = true
    statusMessage = nil
    Task {
      do {
        try await appState.api.validateCredentials()
        await MainActor.run {
          statusMessage = "\(appState.mediaSourceKind.title)连接正常。"
          appState.markMediaConnected()
          isCheckingConnection = false
        }
      } catch {
        await MainActor.run {
          statusMessage = error.localizedDescription
          appState.markMediaOffline()
          isCheckingConnection = false
        }
      }
    }
  }
}

private struct AppearanceSettingsView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    @Bindable var appState = appState

    Form {
      Section("界面") {
        Picker("主题", selection: $appState.colorSchemePreference) {
          ForEach(AppState.ColorSchemePreference.allCases) { scheme in
            Text(scheme.title).tag(scheme)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("资料库") {
        Picker("浏览方式", selection: $appState.browserLayout) {
          ForEach(AppState.BrowserLayout.allCases) { layout in
            Label(layout.title, systemImage: layout.icon).tag(layout)
          }
        }

        if appState.browserLayout == .grid {
          LabeledContent("封面列数") {
            Menu {
              ForEach([2, 3, 4], id: \.self) { count in
                Button {
                  setGridColumnsSafely(count)
                } label: {
                  if appState.gridColumns == count {
                    Label("\(count) 列", systemImage: "checkmark")
                  } else {
                    Text("\(count) 列")
                  }
                }
              }
            } label: {
              Text("\(min(max(appState.gridColumns, 2), 4)) 列")
            }
          }
        }

        Picker("缩略图", selection: $appState.artworkMode) {
          ForEach(AppState.ArtworkMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
      }
    }
    .navigationTitle("外观")
    .navigationBarTitleDisplayMode(.inline)
  }

  @MainActor
  private func setGridColumnsSafely(_ value: Int) {
    let clamped = min(max(value, 2), 4)
    guard clamped != appState.gridColumns else { return }
    Task { @MainActor in
      await Task.yield()
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        appState.gridColumns = clamped
      }
    }
  }
}

private struct PlaybackSettingsView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    @Bindable var appState = appState

    Form {
      Section("基础播放") {
        Picker("默认画质", selection: $appState.defaultQuality) {
          ForEach(AppState.DefaultQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }

        Toggle("快速起播", isOn: $appState.fastStartEnabled)
        Text("优先尽快开始播放并减少起播等待；网络较差时关闭可增加初始缓冲。")
          .font(.caption)
          .foregroundStyle(.secondary)

        Toggle("自动播放下一集", isOn: $appState.autoPlayNextEpisode)
        Text(
          appState.autoPlayNextEpisode
            ? "有下一集时自动播放；最后一个视频自动重播。"
            : "关闭后，当前视频结束会从头重播。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("手势") {
        Toggle("播放器手势", isOn: $appState.playerGesturesEnabled)
        if appState.playerGesturesEnabled {
          Picker("双击快进 / 快退", selection: $appState.doubleTapSeekSeconds) {
            Text("10 秒").tag(10)
            Text("15 秒").tag(15)
            Text("30 秒").tag(30)
          }
        }
      }

      Section("字幕") {
        Toggle("自动载入同名外挂字幕", isOn: $appState.autoLoadExternalSubtitle)

        LabeledContent("字幕大小") {
          Text("\(Int((appState.subtitleFontScale * 100).rounded()))%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Slider(value: $appState.subtitleFontScale, in: 0.8...1.6, step: 0.05)

        LabeledContent("字幕位置") {
          Text("\(Int((appState.subtitleBottomPadding * 100).rounded()))%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Slider(value: $appState.subtitleBottomPadding, in: 0.04...0.28, step: 0.01)

        Stepper(value: $appState.subtitleDelaySeconds, in: -10...10, step: 0.5) {
          LabeledContent("字幕延迟") {
            Text(String(format: "%+.1f 秒", appState.subtitleDelaySeconds))
              .monospacedDigit()
          }
        }
        Text("正数表示字幕更晚出现。支持同目录同名 SRT、WebVTT、ASS、SSA 字幕。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("章节与片头片尾") {
        Toggle("在进度条显示章节标记", isOn: $appState.chapterMarksEnabled)

        Toggle("显示跳过片头", isOn: $appState.skipIntroEnabled)
        if appState.skipIntroEnabled {
          Picker("无章节时片头长度", selection: $appState.introSkipSeconds) {
            ForEach([30, 60, 90, 120, 180], id: \.self) { seconds in
              Text("\(seconds) 秒").tag(seconds)
            }
          }
        }

        Toggle("显示跳过片尾", isOn: $appState.skipOutroEnabled)
        if appState.skipOutroEnabled {
          Picker("无章节时片尾提前", selection: $appState.outroSkipSeconds) {
            ForEach([30, 60, 90, 120, 180, 300], id: \.self) { seconds in
              Text("\(seconds) 秒").tag(seconds)
            }
          }
        }

        Text("优先使用视频内嵌章节或同目录章节文件识别片头 / 片尾；无法识别时再使用上面的固定时间。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("进度条") {
        Toggle("拖动时显示画面预览", isOn: $appState.progressPreviewEnabled)
        Text("缩略图按需生成并缓存，不会预先扫描整部视频。当前主要用于系统 AVPlayer 播放的视频，VLC 兼容播放不会额外解码预览图。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("网络") {
        Toggle("网络自愈", isOn: $appState.networkAutoRecoveryEnabled)
        Text("网络超时、临时断线、429 与服务器 5xx 时自动进行有限次数重试；401 / 403 等鉴权错误不会无限重试。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("播放")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct PrivacySettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var isChangingFaceID = false

  var body: some View {
    Form {
      Section("进入验证") {
        Toggle(
          "\(appState.biometricTitle)进入验证",
          isOn: Binding(
            get: { appState.faceIDEnabled },
            set: { newValue in
              guard !isChangingFaceID else { return }
              isChangingFaceID = true
              Task {
                _ = await appState.setFaceIDProtection(newValue)
                isChangingFaceID = false
              }
            }
          )
        )
        .disabled(isChangingFaceID || (!appState.canUseBiometrics && !appState.faceIDEnabled))

        Text("开启后，冷启动及从后台返回都会先锁定并模糊内容，验证成功后才能继续操作。")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let message = appState.biometricErrorMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("隐私")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct CacheSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var statusMessage: String?
  @State private var showClearRecentsConfirmation = false
  @State private var artworkBytes: Int64?

  var body: some View {
    Form {
      Section("缓存") {
        if let artworkBytes {
          LabeledContent("本地封面", value: ByteCountFormatter.string(fromByteCount: artworkBytes, countStyle: .file))
        }
        Text("已保存的封面长期保留，重启或链接过期不会重新下载。仅文件发生变化、手动清除或卸载 App 后需要重建；清除资料库缓存不会删除封面。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("清除资料库缓存") {
          Task {
            await appState.api.clearMountCache()
            await MainActor.run {
              statusMessage = "资料库缓存已清除，下次进入目录会重新读取服务器。"
            }
          }
        }

        Button("清除封面缓存") {
          Task {
            let cleared = await appState.thumbnailService.clearCache()
            artworkBytes = await appState.thumbnailService.cacheUsageBytes()
            statusMessage = cleared ? "封面缓存已清除。" : "部分封面未能清除，请稍后重试。"
          }
        }

        Button("清除最近播放") {
          showClearRecentsConfirmation = true
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("缓存")
    .navigationBarTitleDisplayMode(.inline)
    .task { artworkBytes = await appState.thumbnailService.cacheUsageBytes() }
    .onChange(of: appState.isAppUnlocked) { _, unlocked in
      if !unlocked { showClearRecentsConfirmation = false }
    }
    .confirmationDialog("清除全部最近播放？", isPresented: $showClearRecentsConfirmation, titleVisibility: .visible) {
      Button("清除播放记录", role: .destructive) {
        appState.libraryStore.clearRecents()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只清除 Cineva 本地播放历史，不会删除服务器文件。")
    }
  }
}

private struct AboutSettingsView: View {
  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          CinevaLogoMark(size: 42)
          VStack(alignment: .leading, spacing: 2) {
            Text("Cineva").font(.headline)
            Text("115 网盘与 OpenList 私人影音播放器")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent("版本", value: "2.2.2")
        LabeledContent("媒体协议", value: "115 Open API + WebDAV")
        LabeledContent("播放内核", value: "AVPlayer + VLC")
      }
    }
    .navigationTitle("关于")
    .navigationBarTitleDisplayMode(.inline)
  }
}
