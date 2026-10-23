enum SoundLinkProtocol {
  audibleNormal(nativeId: 0, framesPerSymbol: 9, bytesPerSymbol: 3, isMonoTone: false),
  audibleFast(nativeId: 1, framesPerSymbol: 6, bytesPerSymbol: 3, isMonoTone: false),
  audibleFastest(nativeId: 2, framesPerSymbol: 3, bytesPerSymbol: 3, isMonoTone: false),
  ultrasoundNormal(nativeId: 3, framesPerSymbol: 9, bytesPerSymbol: 3, isMonoTone: false),
  ultrasoundFast(nativeId: 4, framesPerSymbol: 6, bytesPerSymbol: 3, isMonoTone: false),
  ultrasoundFastest(nativeId: 5, framesPerSymbol: 3, bytesPerSymbol: 3, isMonoTone: false),
  dualToneNormal(nativeId: 6, framesPerSymbol: 9, bytesPerSymbol: 1, isMonoTone: false),
  dualToneFast(nativeId: 7, framesPerSymbol: 6, bytesPerSymbol: 1, isMonoTone: false),
  dualToneFastest(nativeId: 8, framesPerSymbol: 3, bytesPerSymbol: 1, isMonoTone: false),
  monoToneNormal(nativeId: 9, framesPerSymbol: 9, bytesPerSymbol: 1, isMonoTone: true),
  monoToneFast(nativeId: 10, framesPerSymbol: 6, bytesPerSymbol: 1, isMonoTone: true),
  monoToneFastest(nativeId: 11, framesPerSymbol: 3, bytesPerSymbol: 1, isMonoTone: true);

  const SoundLinkProtocol({
    required this.nativeId,
    required this.framesPerSymbol,
    required this.bytesPerSymbol,
    required this.isMonoTone,
  });

  final int nativeId;
  final int framesPerSymbol;
  final int bytesPerSymbol;
  final bool isMonoTone;

  bool get requiresFixedLength => isMonoTone;

  int get bandBins => isMonoTone ? 16 : 32 * bytesPerSymbol;

  int get symbolFrameMultiplier => isMonoTone ? 2 : 1;
}
