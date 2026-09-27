import SwiftUI
import UIKit

struct FFmpegPlayerSurface: UIViewRepresentable {
  let engine: FFmpegPlayerEngine
  let layout: PlayerVideoLayout
  func makeUIView(context: Context) -> Surface {
    let view=Surface(); view.engine=engine
    view.layer.addSublayer(engine.renderer.layer)
    return view
  }
  func updateUIView(_ view: Surface, context: Context) {
    engine.renderer.layer.videoGravity=layout.gravity
    view.setNeedsLayout()
  }
  final class Surface: UIView {
    weak var engine: FFmpegPlayerEngine?
    override func layoutSubviews() {
      super.layoutSubviews()
      guard let engine else { return }
      let layer=engine.renderer.layer, angle=engine.rotation * .pi/180
      let quarter=abs(sin(angle))>0.5
      CATransaction.begin(); CATransaction.setDisableActions(true)
      layer.setAffineTransform(.identity)
      layer.bounds=CGRect(origin:.zero,size:quarter ? CGSize(width:bounds.height,height:bounds.width) : bounds.size)
      layer.position=CGPoint(x:bounds.midX,y:bounds.midY)
      layer.setAffineTransform(CGAffineTransform(rotationAngle:angle))
      CATransaction.commit()
    }
  }
}
