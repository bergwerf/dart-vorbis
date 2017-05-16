// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by a MIT-style license
// that can be found in the LICENSE file.

library vorbis;

import 'dart:io';
import 'dart:typed_data';

import 'package:vorbis/structs.dart';
import 'package:vorbis/internal.dart';

/// Get general file information.
VorbisInfo vorbisGetInfo(Vorbis vorb) {}

/// Get and clear last detected error.
int vorbisGetError(Vorbis vorb) {}

/// Close ogg vorbis file and clear memory.
void vorbisClose(Vorbis vorb) {
  // TODO
}

void vorbisDeinit(Vorbis vorb) {
  // TODO
}

Vorbis vorbisOpenPushdata(Uint8List datablock, VorbisErrorRef error) {
  final p = new Vorbis();
  p.pushMode = true;

  if (!startDecoder(p)) {
    error.value = p.eof ? VorbisError.needMoreData : p.error;
  }

  /*final f = vorbisAlloc(p);
  if (f != null) {
    f = p;
    return f;
  } else {
    vorbisDeinit(p);
    return null;
  }*/
}
