import AVFoundation
import Charts
import HaishinKit
import SwiftUI

enum FPS: String, CaseIterable, Identifiable {
    case fps15 = "15"
    case fps30 = "30"
    case fps60 = "60"

    var frameRate: Float64 {
        switch self {
        case .fps15:
            return 15
        case .fps30:
            return 30
        case .fps60:
            return 60
        }
    }

    var id: Self { self }
}

enum VideoEffectItem: String, CaseIterable, Identifiable, Sendable {
    case none
    case monochrome

    var id: Self { self }

    func makeVideoEffect() -> VideoEffect? {
        switch self {
        case .none:
            return nil
        case .monochrome:
            return MonochromeEffect()
        }
    }
}

struct PublishView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var preference: PreferenceViewModel
    @StateObject private var model = PublishViewModel()

    var body: some View {
        ZStack {
            VStack {
                if preference.viewType == .pip {
                    PiPHKViewRepresentable(previewSource: model)
                } else {
                    MTHKViewRepresentable(previewSource: model)
                }
            }
            VStack {
                Spacer()
                Chart(model.stats) {
                    LineMark(
                        x: .value("time", $0.date),
                        y: .value("currentBytesOutPerSecond", $0.currentBytesOutPerSecond)
                    )
                }
                .frame(height: 300)
                .padding(32)
            }
            VStack {
                HStack(spacing: 16) {
                    if !model.audioSources.isEmpty {
                        Picker("AudioSource", selection: $model.audioSource) {
                            ForEach(model.audioSources, id: \.description) { source in
                                Text(source.description).tag(source)
                            }
                        }
                        .frame(width: 200)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(16)
                        .padding(16)
                    }
                    Spacer()
                    Button(action: {
                        model.toggleRecording()
                    }, label: {
                        Image(systemName: model.isRecording ?
                                "recordingtape.circle.fill" :
                                "recordingtape.circle")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    })
                    Button(action: {
                        model.toggleAudioMuted()
                    }, label: {
                        Image(systemName: model.isAudioMuted ?
                                "microphone.slash.circle" :
                                "microphone.circle")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    })
                    Button(action: {
                        model.flipCamera()
                    }, label: {
                        Image(systemName:
                                "arrow.trianglehead.2.clockwise.rotate.90.camera")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    })
                    Button(action: {
                        model.toggleTorch()
                    }, label: {
                        Image(systemName: model.isTorchEnabled ?
                                "flashlight.on.circle.fill" :
                                "flashlight.off.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    })
                }
                .frame(height: 50)
                HStack {
                    Spacer()
                    Toggle(isOn: $model.isHDREnabled) {
                        Text("HDR")
                    }.frame(width: 120)
                    Picker("FPS", selection: $model.currentFPS) {
                        ForEach(FPS.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .onChange(of: model.currentFPS) { tag in
                        model.setFrameRate(tag.frameRate)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }.frame(height: 80)
                Spacer()
                TabView(selection: $model.visualEffectItem) {
                    ForEach(VideoEffectItem.allCases) {
                        Text($0.rawValue).padding()
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
                .frame(height: 100)
                .onChange(of: model.visualEffectItem) { tag in
                    model.setVisualEffet(tag)
                }
                HStack {
                    Slider(
                        value: $model.videoBitRates,
                        in: 100...4000,
                        step: 100
                    ) {
                        Text("Video BitRate(kbp)")
                    } minimumValueLabel: {
                        Text("100")
                    } maximumValueLabel: {
                        Text("4,000")
                    }
                    .padding(.leading, 32)
                    .frame(maxWidth: .infinity)
                    Text("\(Int(model.videoBitRates))/kbps")
                    Spacer()
                    switch model.readyState {
                    case .connecting:
                        Spacer()
                    case .open:
                        Button(action: {
                            model.stopPublishing()
                        }, label: {
                            Image(systemName: "stop.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    case .closing:
                        Spacer()
                    case .closed:
                        Button(action: {
                            model.startPublishing(preference)
                        }, label: {
                            Image(systemName: "record.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16.0))
                    }
                }.frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            model.startRunning(preference)
        }
        .onDisappear {
            model.stopRunning()
        }
        .onChange(of: horizontalSizeClass) { _ in
            model.orientationDidChange()
        }.alert(isPresented: $model.isShowError) {
            Alert(
                title: Text("Error"),
                message: Text(String(describing: model.error)),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

#Preview {
    PublishView()
}
