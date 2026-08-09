/// 一帧频谱（C 引擎输出的前端契约：128 bins，对数映射 80~2000Hz，归一化 [0,1]，§10.1）。
class FftFrame {
  const FftFrame({required this.ldata, required this.rdata});

  final List<double> ldata;
  final List<double> rdata;
}
