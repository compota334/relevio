"""relevio: read an OpenTimestamps proof without a Bitcoin node.

Run by relevio-archive-stamps.sh with the Python of relevio's own virtual
environment (where opentimestamps-client is installed), never with the
system's. It only reads the proof file given; it never touches the network.

  attest <file.ots>...  one line per attestation, named by the file's base name
                         (many files in one call: one Python start for all):
                           <name> bitcoin <block height> <merkle root, explorer byte order>
                           <name> pending <calendar url>
  digest <file.ots>      the sha256 of the stamped file, as the proof records it
"""
import os
import sys

from opentimestamps.core.notary import BitcoinBlockHeaderAttestation, PendingAttestation
from opentimestamps.core.serialize import StreamDeserializationContext
from opentimestamps.core.timestamp import DetachedTimestampFile


def load(path):
    with open(path, "rb") as f:
        return DetachedTimestampFile.deserialize(StreamDeserializationContext(f))


def main(argv):
    if len(argv) < 3 or argv[1] not in ("attest", "digest") or (argv[1] == "digest" and len(argv) != 3):
        sys.stderr.write("usage: relevio-ots-helper.py attest <file.ots>... | digest <file.ots>\n")
        return 2
    rc = 0
    for path in argv[2:]:
        try:
            proof = load(path)
        except Exception as e:  # a damaged proof must fail loud, with its reason
            sys.stderr.write("%s: not a readable OpenTimestamps proof: %s\n" % (path, type(e).__name__))
            rc = 1
            continue
        if argv[1] == "digest":
            print(proof.file_digest.hex())
            continue
        name = os.path.basename(path)
        for msg, att in proof.timestamp.all_attestations():
            if isinstance(att, BitcoinBlockHeaderAttestation):
                # Explorers show the merkle root byte-reversed.
                print("%s bitcoin %d %s" % (name, att.height, msg[::-1].hex()))
            elif isinstance(att, PendingAttestation):
                print("%s pending %s" % (name, att.uri))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
