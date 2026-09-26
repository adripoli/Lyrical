//
//  StableHash.swift
//  Lyrical
//
//  FNV-1a, 64-bit. Used wherever a hash must be identical on every launch
//  (cache filenames, fallback gradient colours). Swift's Hasher is randomly
//  seeded per process, so it can't be used for either.
//

enum StableHash {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
