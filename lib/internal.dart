// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by a MIT-style license
// that can be found in the LICENSE file.

library vorbis.internal;

import 'dart:io';
import 'dart:typed_data';

import 'package:vorbis/structs.dart';

/// Set [error] in [vorb] handler, and return false (error states are signalled
/// by terminating functions with false).
bool error(Vorbis vorb, VorbisError error) {
  vorb.error = error;
  if (!vorb.eof && error != VorbisError.needMoreData) {
    vorb.error = error; // Breakpoint for debugging
  }
  return false;
}

/// Get next uint8 from the [vorb] handler.
/// See stb_vorbis.c:1262
int get8(Vorbis vorb) {
  /// Either we are reading from a stream, or from a file.
  if (vorb.isStreaming) {
    // Would check if there is data left in the stream, and return it or set
    // eof and return 0.
    throw new UnimplementedError();
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

/// Get next uint32 in stream.
/// See stb_vorbis.c:1283
int get32(Vorbis vorb) {
  // Note: By masking with 0x3fffffff, the Dart VM knows that the result will
  // fit in a small integer.
  int x;
  x = get8(vorb);
  x += (get8(vorb) << 8) & 0x3fffffff;
  x += (get8(vorb) << 16) & 0x3fffffff;
  x += (get8(vorb) << 24) & 0x3fffffff;
  return x;
}

/// Copy next [buffer].length bytes in stream to [buffer].
/// See stb_vorbis.c:1292
bool getn(Vorbis vorb, Uint8List buffer) {
  if (vorb.isStreaming) {
    throw UnimplementedError();
  } else {
    try {
      // Fill buffer from opened file. The buffer size has been determined by
      // the caller.
      vorb.f.readIntoSync(buffer);
      return true;
    } on FileSystemException {
      // Maybe the file is too small? Anyway, this will terminate the operation.
      vorb.eof = true;
      return false;
    }
  }
}

/// Skip n bytes in the [vorb] handler.
/// See stb_vorbis.c:1313
void skip(Vorbis vorb, int n) {
  if (vorb.isStreaming) {
    throw UnimplementedError();
  } else {
    final x = vorb.f.positionSync();
    vorb.f.setPositionSync(x + n);
  }
}

/// Set reading position in the file.
/// See stb_vorbis.c:1327
bool setFileOffset(Vorbis vorb, int loc) {
  if (vorb.isStreaming) {
    throw UnimplementedError();
  } else {
    try {
      vorb.f.setPositionSync(loc);
      return true;
    } on FileSystemException {
      vorb.eof = true;
      return false;
    }
  }
}

/// See stb_vorbis.c:1358
const oggPageHeader = const [0x4f, 0x67, 0x67, 0x53];

/// Check if we are at an OGG capture pattern: 'OggS'
/// See stb_vorbis.c:1360
bool isCapturePattern(Vorbis vorb) {
  return get8(vorb) == 0x4f &&
      get8(vorb) == 0x67 &&
      get8(vorb) == 0x67 &&
      get8(vorb) == 0x53;
}

/// Page flags
/// See stb_vorbis.c:1368
const pageflagContinuedPacket = 1 << 0;
const pageflagFirstPage = 1 << 1;
const pageflagLastPage = 1 << 2;

/// See stb_vorbis.c:1372
/// Start reading a page without checking for a capture pattern.
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
  // Note that ~0U == -1
  if (loc0 != -1 && loc1 != -1) {
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

/// See stb_vorbis.c:1424
bool startPage(Vorbis vorb) {
  if (!isCapturePattern(vorb)) {
    return error(vorb, VorbisError.missingCaputurePattern);
  } else {
    return startPageNoCapturePattern(vorb);
  }
}

/// See stb_vorbis.c:1429
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

/// See stb_vorbis.c:1443
bool maybeStartPacket(Vorbis vorb) {
  if (vorb.nextSeg == -1) {
    final x = get8(vorb);
    if (vorb.eof) {
      // EOF at page boundary is not an error!
      return false;
    }

    // Check for capture pattern.
    if (x != 0x4f ||
        get8(vorb) != 0x67 ||
        get8(vorb) != 0x67 ||
        get8(vorb) != 0x53) {
      return error(vorb, VorbisError.missingCaputurePattern);
    }

    if (!startPageNoCapturePattern(vorb)) {
      return false;
    }

    if (vorb.pageFlag & pageflagContinuedPacket != 0) {
      // Set up enough state so that we can read this packet if we want,
      // e.g. during recovery.
      vorb.lastSeg = false;
      vorb.bytesInSeg = 0;
      return error(vorb, VorbisError.continuedPacketFlagInvalid);
    }
  }
  return startPacket(vorb);
}

/// Header values
const vorbisPacketId = 1;
const vorbisPacketComment = 3;
const vorbisPackeassumetSetup = 5;

bool startDecoder(Vorbis vorb) {
  // First page, first packet
  if (startPage(vorb)) {
    return false;
  }

  // Validate page flag.
  if (vorb.pageFlag & pageflagContinuedPacket == 0 ||
      vorb.pageFlag & pageflagLastPage != 0 ||
      vorb.pageFlag & pageflagContinuedPacket != 0) {
    return error(vorb, VorbisError.invalidFirstPage);
  }

  // Check for expected packet length.
  if (vorb.segmentCount != 1 || vorb.segments[0] != 30) {
    return error(vorb, VorbisError.invalidFirstPage);
  }

  // Start reading packet.
  // Check packet header.
  if (get8(vorb) != vorbisPacketId) {
    return error(vorb, VorbisError.invalidFirstPage);
  }

  // Read header.
  final header = new Uint8List(6);
  if (!getn(vorb, header)) {
    return error(vorb, VorbisError.unexpectedEof);
  }
  if (!vorbisValidate(header)) {
    return error(vorb, VorbisError.invalidFirstPage);
  }

  // Check version.
  if (get32(vorb) != 0) {
    return error(vorb, VorbisError.invalidFirstPage);
  }

  // Get channels and sample rate.
  vorb.channels = get8(vorb);
  if (vorb.channels == 0) {
    return error(vorb, VorbisError.invalidFirstPage);
  }
  vorb.sampleRate = get32(vorb);
  if (vorb.sampleRate == 0) {
    return error(vorb, VorbisError.invalidFirstPage);
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
    return error(vorb, VorbisError.invalidFirstPage);
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
