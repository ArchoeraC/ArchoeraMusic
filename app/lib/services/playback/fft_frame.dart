/// 一帧频谱（C 引擎输出的前端契约：128 bins，对数映射 80~2000Hz，归一化 [0,1]，§10.1）。
class FftFrame {
  const FftFrame({required this.ldata, required this.rdata, this.beatStrength = 0});

  final List<double> ldata;
  final List<double> rdata;

  /// 本帧脉冲强度 0~1（C 引擎节拍检测结果——低/中/高频能量突增的
  /// 加权综合强度，不限于鼓点；封面跟随节奏缩放按此区分脉冲大小）。
  /// 拉模式下与频谱同帧输出；无脉冲为 0。
  final double beatStrength;

  /// 本帧是否有脉冲（[beatStrength] > 0）。
  bool get beat => beatStrength > 0;
}
