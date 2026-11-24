"""relevio: read an OpenTimestamps proof without a Bitcoin node.

Run by relevio-archive-stamps.sh with the Python of relevio's own virtual
environment (where opentimestamps-client is installed), never with the
system's. It only reads the proof file given; it never touches the network.

  attest <file.ots>   one line per attestation:
                        bitcoin <block height> <merkle root, explorer byte order>
                        pending <calendar url>
  digest <file.ots>   the sha256 of the stamped file, as the proof records it
"""
import sys

from opentimestamps.core.notary import BitcoinBlockHeaderAttestation, PendingAttestation
from opentimestamps.core.serialize import StreamDeserializationContext
from opentimestamps.core.timestamp import DetachedTimestampFile


def load(path):
    with open(path, "rb") as f:
        return DetachedTimestampFile.deserialize(StreamDeserializationContext(f))


def main(argv):
    if len(argv) != 3 or argv[1] not in ("attest", "digest"):
        sys.stderr.write("usage: relevio-ots-helper.py attest|digest <file.ots>\n")
        return 2
    try:
        proof = load(argv[2])
    except Exception as e:  # a damaged proof must fail loud, with its reason
        sys.stderr.write("not a readable OpenTimestamps proof: %s\n" % type(e).__name__)
        return 1
    if argv[1] == "digest":
        print(proof.file_digest.hex())
        return 0
    for msg, att in proof.timestamp.all_attestations():
        if isinstance(att, BitcoinBlockHeaderAttestation):
            # Explorers show the merkle root byte-reversed.
            print("bitcoin %d %s" % (att.height, msg[::-1].hex()))
        elif isinstance(att, PendingAttestation):
            print("pending %s" % att.uri)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
