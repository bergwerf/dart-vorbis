// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by a MIT-style license
// that can be found in the LICENSE file.

library vorbis.structs;

import 'dart:io';
import 'dart:typed_data';

class VorbisInfo {
  int sampleRate;
  int channels;

  int setupMemoryRequired;
  int setupTempMemoryRequired;
  int tempMemoryRequired;

  int maxFrameSize;
}

/// Error codes
enum VorbisError {
  noError,
  needMoreData,

  /// Can't mix API methods
  invalidApiMixing,

  /// When user floor 0
  featureNotSupported,

  /// [vorbisMaxChannels] is too small
  tooManyChannels,

  /// Truncated file?
  unexpectedEof,

  // Vorbis errors
  invalidSetup,
  invalidStream,

  // OGG errors
  missingCaputurePattern,
  invalidStreamStructureVersion,
  continuedPacketFlagInvalid,
  incorrectStreamSerialNumber,
  invalidFirstPage,
  badPacketType,
  cantFindLastPage,
  seekFailed
}

class VorbisErrorRef {
  var value = VorbisError.noError;
}

/// Globally define this to the maximum number of channels you need.
/// The spec does not put a restriction on channels except that
/// the count is stored in a byte, so 255 is the hard limit.
/// Reducing this saves about 16 bytes per value, so using 16 saves
/// (255-16)*16 or around 4KB. Plus anything other memory usage
/// I forgot to account for. Can probably go as low as 8 (7.1 audio),
/// 6 (5.1 audio), or 2 (stereo only).
var vorbisMaxChannels = 16;

/// After a [flushPushdata], vorbis begins scanning for the
/// next valid page, without backtracking. when it finds something
/// that looks like a page, it streams through it and verifies its
/// CRC32. Should that validation fail, it keeps scanning. But it's
/// possible that _while_ streaming through to check the CRC32 of
/// one candidate page, it sees another candidate page. This variable
/// determines how many "overlapping" candidate pages it can search
/// at once. Note that "real" pages are typically ~4KB to ~8KB, whereas
/// garbage pages could be as big as 64KB, but probably average ~16KB.
/// So don't hose ourselves by scanning an apparent 64KB page and
/// missing a ton of real ones in the interim; so minimum of 2
var vorbisPushdataCrcCount = 4;

/// Sets the log size of the huffman-acceleration table. Maximum
/// supported value is 24. with larger numbers, more decodings are O(1),
/// but the table size is larger so worse cache missing, so you'll have
/// to probe (and try multiple ogg vorbis files) to find the sweet spot.
var vorbisFastHuffmanLength = 10;

/// From specification.
const maxBlocksizeLog = 13;
const maxBlocksize = 1 << maxBlocksizeLog;

int get fastHuffmanTableSize => 1 << vorbisFastHuffmanLength;
int get fastHuffmanTableMask => fastHuffmanTableSize - 1;

class Codebook {
  int dimensions, entries;
  Uint8List codewordLengths;
  double minimumValue;
  double deltaValue;
  int valueBits;
  int lookupType;
  int sequenceP;
  int sparse;
  int lookupValues;
  Float32List multiplicands;
  Uint32List codewords;
  Int32List fastHuffman;
  Uint32List sortedCodewords;
  List<int> sortedValues;
  int sortedEntries;
}

class Floor0 {
  int order;
  int rate;
  int barkMapSize;
  int amplitudeBits;
  int amplitudeOffset;
  int numberOfBooks;
  Uint8List bookList;
}

class Floor1 {
  int partitions;
  Uint8List partitionClassList;
  Uint8List classDimensions;
  Uint8List classSubclasses;
  Uint8List classMasterbooks;
  Int16List subclassBooks;
  Uint16List xlist;
  Uint8List sortedOrder;
  Uint8List neighbors;
  int floor1Multiplier;
  int rangebits;
  int values;
}

class Floor {
  Floor0 floor0;
  Floor1 floor1;
}

class Residue {
  int begin, end;
  int partSize;
  int classifications;
  int classbook;
  Uint8List classdata;
  Int16List residueBooks;
}

class MappingChannel {
  int magnitude;
  int angle;
  int mux;
}

class Mapping {
  int couplingSteps;
  MappingChannel chan;
  int submaps;
  Uint8List submapFloor;
  Uint8List submapResidue;
}

class Mode {
  int blockflag;
  int mapping;
  int windowType;
  int transformType;
}

class CRCscan {
  int goalCrc; // expected crc if match
  int bytesLeft; // bytes left in packet
  int crcSoFar; // running crc
  int bytesDone; // bytes processed in _current_ chunk
  int sampleLoc; // granule pos encoded in page
}

class ProbedPage {
  int pageStart, pageEnd;
  int lastDecodedSample;
}

class Vorbis {
  // user-accessible info
  int sampleRate;
  int channels;

  /*int setupMemoryRequired;
  int setupTempMemoryRequired;
  int tempMemoryRequired;*/

  RandomAccessFile f;
  //int fStart;
  //bool closeOnFree = false;

  //int stream;
  //int streamStart;
  //int streamEnd;

  //int streamLen;

  bool pushMode;

  int firstAudioPageOffset;

  ProbedPage pFirst, pLast;

  // Run-time results
  bool eof = false;
  var error = VorbisError.noError;

  // Header info
  //final blocksize = new List<int>(2);
  int blocksize0, blocksize1;
  //List<Codebook> codebooks;
  //Uint16List floorTypes;
  //List<Floor> floorConfig;
  //Uint16List residueTypes;
  //List<Residue> residueConfig;
  //List<Mapping> mapping;
  //List<Mode> modeConfig;

  //int totalSamples;

  // decode buffer
  //List<double> channelBuffers; // * STB_VORBIS_MAX_CHANNELS
  //List<double> outputs; // * STB_VORBIS_MAX_CHANNELS

  //List<double> previousWindow; // * STB_VORBIS_MAX_CHANNELS
  //int previousLength;

  //Int16List finalY; // * STB_VORBIS_MAX_CHANNELS

  //int currentLoc; // sample location of next frame to decode
  //int currentLocValid;

  // per-blocksize precomputed data

  // twiddle factors
  /*float *A[2],*B[2],*C[2];
   float *window[2];
   uint16 *bit_reverse[2];*/

  // current page/packet/segment streaming info
  //int serial; // stream serial number for verification
  int lastPage;
  int segmentCount;
  Uint8List segments;
  int pageFlag;
  int bytesInSeg;
  bool firstDecode = false;
  int nextSeg;
  bool lastSeg; // flag that we're on the last segment
  int lastSegWhich; // what was the segment number of the last seg?
  //int acc;
  int validBits;
  int packetBytes;
  int endSegWithKnownLoc;
  int knownLocForPacket;
  //int discardSamplesDeferred;
  //int samplesOutput;

  /// Push mode scanning
  /// Only in push_mode: number of tests active; -1 if not searching
  //int pageCrcTests = -1;

  List<CRCscan> scan;

  // sample-access
  //int channelBufferStart;
  //int channelBufferEnd;

  Vorbis() : scan = new List<CRCscan>(vorbisPushdataCrcCount);

  /// TODO: implement
  bool get isStreaming => false;
}
