// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by a MIT-style license
// that can be found in the LICENSE file.

library vorbis.internal;

import 'dart:io';
import 'dart:typed_data';

import 'package:vorbis/structs.dart';

bool error(Vorbis vorb, VorbisError error) {
  vorb.error = error;
  if (!vorb.eof && error != VorbisError.needMoreData) {
    vorb.error = error; // Breakpoint for debugging
  }
  return false;
}

/// Get next byte in stream.
int get8(Vorbis vorb) {
  if (vorb.isStreaming) {
    /*if (z->stream >= z->stream_end) {
      z.eof = true;
      return 0;
    } else {
      return *z->stream++;
    }*/
  } else {
    final c = vorb.f.readByteSync();
    if (c == -1) {
      vorb.eof = true;
      return 0;
    } else {
      return c;
    }
  }
}

/// Get next 32bit integer in stream.
int get32(Vorbis vorb) {
  // TODO: left shift optimization
  int x;
  x = get8(vorb);
  x += get8(vorb) << 8;
  x += get8(vorb) << 16;
  x += get8(vorb) << 24;
  return x;
}

/// Copy next [buffer].length bytes in stream to [buffer].
bool getn(Vorbis vorb, Uint8List buffer) {
  if (vorb.isStreaming) {
    // TODO
  } else {
    try {
      vorb.f.readIntoSync(buffer);
      return true;
    } catch (e) {
      vorb.eof = true;
      return false;
    }
  }
}

void skip(Vorbis vorb, int n) {
  if (vorb.isStreaming) {
    // TODO
  } else {
    final x = vorb.f.positionSync();
    vorb.f.setPositionSync(x + n);
  }
}

/// Page flags
const pageflagContinuedPacket = 1 << 0;
const pageflagFirstPage = 1 << 1;
const pageflagLastPage = 1 << 2;

/// Header values
const vorbisPacketId = 1;
const vorbisPacketComment = 3;
const vorbisPacketSetup = 5;

bool startDecoder(Vorbis vorb) {
  // First page, first packet
  if (startPage(vorb)) {
    return false;
  }

  // Validate page flag.
  if (vorb.pageFlag & pageflagContinuedPacket == 0 ||
      vorb.pageFlag & pageflagLastPage != 0 ||
      vorb.pageFlag & pageflagContinuedPacket != 0) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Check for expected packet length.
  if (vorb.segmentCount != 1 || vorb.segments[0] != 30) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Start reading packet.
  // Check packet header.
  if (get8(vorb) != vorbisPacketId) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Read header.
  final header = new Uint8List(6);
  if (!getn(vorb, header)) {
    return error(vorb, VorbisError.unexpectedEof);
  }
  if (!vorbisValidate(header)) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Check version.
  if (get32(vorb) != 0) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Get channels and sample rate.
  vorb.channels = get8(vorb);
  if (vorb.channels == 0) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }
  vorb.sampleRate = get32(vorb);
  if (vorb.sampleRate == 0) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Discard
  get32(vorb); // bitrate maximum
  get32(vorb); // bitrate nominal
  get32(vorb); // bitrate minimum

  // Setup
  final x = get8(vorb);
  final log0 = x & 15;
  final log1 = x >> 4;
  vorb.blocksize0 = 1 << log0;
  vorb.blocksize1 = 1 << log1;
  if (log0 < 6 || log0 > 13 || log1 < 6 || log1 > 13 || log0 > log1) {
    return error(vorb, VorbisError.invalidSetup);
  }

  // Framing flag
  final xx = get8(vorb);
  if (xx & 1 == 0) {
    return error(vorb, VorbisError.invalidFisrtPage);
  }

  // Second packet!
  if (!startPage(vorb)) {
    return false;
  }
  if (!startPacket(vorb)) {
    return false;
  }
  int len;
  do {
    len = nextSegment(vorb);
    skip(vorb, len);
    vorb.bytesInSeg = 0;
  } while (len != 0);

  // Third packet!
  if (!startPacket(vorb)) {
    return false;
  }

  // TODO: there is still a long way to go from here.
}

/// Validate header signature.
bool vorbisValidate(Uint8List data) {
  final vorbis = 'vorbis'.codeUnits;
  assert(data.length == 6);
  for (var i = 0; i < data.length; i++) {
    if (data[i] != vorbis[i]) {
      return false;
    }
  }
  return true;
}

/// Returns segment length.
int nextSegment(Vorbis vorb) {
  if (vorb.lastSeg) {
    return 0;
  }
  if (vorb.nextSeg == -1) {
    vorb.lastSegWhich = vorb.segmentCount = 1; // in case [startPage] fails.
    if (!startPage(vorb)) {
      vorb.lastSeg = true;
      return 0;
    }
    if (vorb.pageFlag & pageflagContinuedPacket == 0) {
      error(vorb, VorbisError.continuedPacketFlagInvalid);
      return 0;
    }
  }

  final len = vorb.segments[vorb.nextSeg++];
  if (len < 255) {
    vorb.lastSeg = true;
    vorb.lastSegWhich = vorb.nextSeg - 1;
  }
  if (vorb.nextSeg >= vorb.segmentCount) {
    vorb.nextSeg = -1;
  }

  assert(vorb.bytesInSeg == 0);
  vorb.bytesInSeg = len;
  return len;
}

bool startPacket(Vorbis vorb) {
  while (vorb.nextSeg == -1) {
    if (!startPage(vorb)) {
      return false;
    }
    if (vorb.pageFlag & pageflagContinuedPacket != 0) {
      return error(vorb, VorbisError.continuedPacketFlagInvalid);
    }
  }
  vorb.lastSeg = false;
  vorb.validBits = 0;
  vorb.packetBytes = 0;
  vorb.bytesInSeg = 0;

  return true;
}

bool startPage(Vorbis vorb) {
  if (!capturePattern(vorb)) {
    return error(vorb, VorbisError.missingCaputurePattern);
  } else {
    return startPageNoCapturePattern(vorb);
  }
}

bool startPageNoCapturePattern(Vorbis vorb) {
  // Stream structure version
  if (get8(vorb) == 0) {
    return error(vorb, VorbisError.invalidStreamStructureVersion);
  }

  // Header flag
  vorb.pageFlag = get8(vorb);

  // Absolute granule position
  final loc0 = get32(vorb);
  final loc1 = get32(vorb);

  // Stream serial number: vorbis doesn't interleave, so discard.
  get32(vorb);

  // Page sequence number
  final n = get32(vorb);
  vorb.lastPage = n;

  // Discard CRC32.
  get32(vorb);

  // Page segments
  vorb.segmentCount = get8(vorb);
  vorb.segments = new Uint8List(vorb.segmentCount);
  if (!getn(vorb, vorb.segments)) {
    return error(vorb, VorbisError.unexpectedEof);
  }

  // Assume we don't know any sample position of any segment.
  vorb.endSegWithKnownLoc = -2;
  // TODO: is this correct?
  if (loc0 != ~0 && loc1 != ~0) {
    int i;
    // Determine which packet is the last one that will complete.
    for (i = vorb.segmentCount - 1; i >= 0; --i) {
      if (vorb.segments[i] < 255) {
        break;
      }
    }

    // [i] is now the index of the last segment of a packet that ends.
    if (i >= 0) {
      vorb.endSegWithKnownLoc = i;
      vorb.knownLocForPacket = loc0;
    }
  }
  if (vorb.firstDecode) {
    var len = 0;
    for (var i = 0; i < vorb.segmentCount; ++i) {
      len += vorb.segments[i];
    }
    len += 27 + vorb.segmentCount;
    final p = new ProbedPage();
    p.pageStart = vorb.firstAudioPageOffset;
    p.pageEnd = p.pageStart + len;
    vorb.pFirst = p;
  }
  vorb.nextSeg = 0;
  return true;
}

/// Check if we are at an OGG capture pattern: 'OggS'
bool capturePattern(Vorbis vorb) {
  return (0x4f == get8(vorb) && //
      (0x67 == get8(vorb) && //
          (0x67 == get8(vorb) && //
              0x53 == get8(vorb))));
}
