import Charts
import FanCore
import SwiftUI

struct OverviewView: View {
    let model: StatusModel
    let status: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlassGroup(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    temperatureCard
                    fanCard
                }
            }
            HStack(alignment: .top, spacing: 16) {
                profileCard
                systemCard
            }
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("强力压制", symbol: "speaker.slash")
                Text("风扇突然变吵时使用：瞬间压到最低转速 60 秒，给你时间关闭高负载软件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SuppressControl(model: model, status: status)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .glassCard()
            HistoryCard(history: model.history, maxRPM: status.fans.map(\.maxRPM).max() ?? 6000)
            if let note = status.lastError { NoticeRow(text: note) }
            if let m = model.message { NoticeRow(text: m, tint: .blue) }
        }
    }

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle("温度", symbol: "thermometer.medium")
            HStack(spacing: 36) {
                TemperatureMetric(title: "CPU", value: status.cpuTemp, size: 52)
                TemperatureMetric(title: "GPU", value: status.gpuTemp, size: 52)
            }
            Text("控制温度取 CPU、GPU 传感器中的最高值")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(20)
        .glassCard(tint: Palette.temperature(status.controlTemp).opacity(0.10))
    }

    private var fanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(status.fans.count > 1 ? "风扇 ×\(status.fans.count)" : "风扇", symbol: "fan")
            if status.fans.isEmpty {
                Text("本机没有风扇").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 28) {
                    ForEach(status.fans, id: \.index) { f in
                        VStack(spacing: 8) {
                            FanGauge(fan: f, large: true)
                            Text("\(Int(f.minRPM))–\(Int(f.maxRPM)) RPM")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(20)
        .glassCard()
    }

    private var profileCard: some View {
        let profile = status.selectedProfile
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle("当前档位", symbol: profile.symbolName)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(profile.displayName).font(.title2.weight(.semibold))
                if profile == .smart {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(status.activeProfile.displayName).font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.profile(status.activeProfile))
                }
            }
            Text(profile == .smart ? (status.smartReason ?? "") : profile.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(status.activeProfile.strategyDetail(for: status.fans))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if profile == .smart {
                QuietFirstToggle(model: model, status: status).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .padding(20)
        .glassCard(tint: Palette.profile(status.activeProfile).opacity(0.12))
    }

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle("系统", symbol: "cpu")
            LabeledContent("CPU 负载", value: status.cpuLoad.map { "\(Int($0 * 100))%" } ?? "--")
            LabeledContent("供电", value: status.onBattery ? "电池" : "电源适配器")
            LabeledContent("热压力", value: status.thermal.displayName)
            LabeledContent("控制状态", value: status.state.displayName)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .padding(20)
        .glassCard()
    }
}

struct CardTitle: View {
    let text: String
    let symbol: String

    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

private struct HistoryCard: View {
    let history: [HistorySample]
    let maxRPM: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle("最近 5 分钟", symbol: "chart.xyaxis.line")
                Spacer()
                Text("窗口打开期间记录").font(.caption).foregroundStyle(.tertiary)
            }
            if history.count < 2 {
                Text("正在收集数据…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                temperatureChart
                rpmChart
            }
        }
        .padding(20)
        .glassCard()
    }

    private var temperatureChart: some View {
        Chart {
            ForEach(history) { s in
                if let c = s.cpu {
                    LineMark(x: .value("时间", s.date), y: .value("温度", c), series: .value("传感器", "CPU"))
                        .foregroundStyle(by: .value("传感器", "CPU"))
                        .interpolationMethod(.monotone)
                }
                if let g = s.gpu {
                    LineMark(x: .value("时间", s.date), y: .value("温度", g), series: .value("传感器", "GPU"))
                        .foregroundStyle(by: .value("传感器", "GPU"))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(["CPU": Palette.cpu, "GPU": Palette.gpu])
        .chartYScale(domain: 20...110)
        .chartYAxis { AxisMarks(values: [30, 50, 70, 90, 110]) { v in
            AxisGridLine()
            AxisValueLabel { if let d = v.as(Int.self) { Text("\(d)°") } }
        } }
        .frame(height: 150)
        .accessibilityLabel("CPU 与 GPU 温度曲线")
    }

    private var rpmChart: some View {
        Chart {
            ForEach(history) { s in
                if let r = s.rpm {
                    AreaMark(x: .value("时间", s.date), y: .value("转速", r))
                        .foregroundStyle(.linearGradient(colors: [Palette.fan.opacity(0.45), Palette.fan.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("时间", s.date), y: .value("转速", r))
                        .foregroundStyle(Palette.fan)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...maxRPM)
        .chartYAxis { AxisMarks { v in
            AxisGridLine()
            AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0fk", d / 1000)) } }
        } }
        .frame(height: 110)
        .accessibilityLabel("风扇转速曲线")
    }
}
