#!/bin/bash
# Runs lab.sh across DIRD versions, ingress MTUs and client MTUs, and checks the results.
# See https://github.com/newsnowlabs/docker-ingress-routing-daemon/issues/43
#
# Requires: root, iproute2, iptables, python3, git; run on a disposable host or VM.
#
# Usage: run-matrix.sh [<base-ref> [<proposal-ref>]]
#
#   <base-ref>      - DIRD before any fix                     (default: v4.3.0 commit 41af82c)
#   <proposal-ref>  - DIRD with only the fix proposed in #43  (default: 49a90f9)
#   The working-tree script is tested as the full fix.

HERE=$(dirname $(realpath $0))
REPO=$(git -C $HERE rev-parse --show-toplevel)
BASE_REF="${1:-41af82c}"
PROPOSAL_REF="${2:-49a90f9}"

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
git -C $REPO show $BASE_REF:docker-ingress-routing-daemon > $TMP/base
git -C $REPO show $PROPOSAL_REF:docker-ingress-routing-daemon > $TMP/proposal
cp $REPO/docker-ingress-routing-daemon $TMP/fixed

PASS=0 FAIL=0

# check <description> <version> <overlay-mtu> <client-mtu> <blackhole|-> <lbrule|-> <expected client_mss> <expected received> [<expected mark>]
#   An expected <received> of "?" means no reply reached the client at all (stall in both directions).
check() {
  local DESC="$1" V="$2" OMTU="$3" CMTU="$4" BH="$5" RULE="$6" EMSS="$7" ERECV="$8" EMARK="${9:-}"
  [ "$BH" = "-" ] && BH=""
  [ "$RULE" = "-" ] && RULE=""
  local OUT=$(OVERLAY_MTU=$OMTU CLIENT_MTU=$CMTU LBRULE="$RULE" $HERE/lab.sh $TMP/$V $BH 2>&1)
  local RES=$(echo "$OUT" | grep '^RESULT')
  local MSS=$(echo "$RES" | sed -nr 's/.*client_mss=([0-9?]+).*/\1/p')
  local RECV=$(echo "$RES" | sed -nr 's/.*received=([0-9?]+).*/\1/p')
  local MARK=$(echo "$RES" | sed -nr 's/.*mark=([0-9?]+).*/\1/p')
  local OK=1
  [ "$MSS" = "$EMSS" ] || OK=0
  [ "$RECV" = "$ERECV" ] || OK=0
  [ -n "$EMARK" ] && [ "$MARK" != "$EMARK" ] && OK=0
  if [ $OK = 1 ]; then ((PASS+=1)); echo "PASS  $DESC"; else ((FAIL+=1)); echo "FAIL  $DESC"; fi
  printf "      version=%-8s ingress_mtu=%-4s client_mtu=%-4s %-9s => %s\n" $V $OMTU $CMTU "${BH:-pmtud-ok}" "${RES#RESULT }"
  echo "$OUT" | grep -E 'Capping' | sed 's/^/      /'
}

echo "### Issue #43 reproduction: unfixed DIRD advertises an MSS derived from the 1500-MTU default route"
check "unfixed, working PMTUD: oversized segments recovered via ICMP"         base 1450 1500 -         - 1448 3000
check "unfixed, PMTUD black hole: client->server data stalls"                  base 1450 1500 blackhole - 1448 0

echo "### Load-balancer TCPMSS rules on the unfixed DIRD"
check "clamping only incoming SYNs does not help client->server"               base 1450 1500 blackhole "-t mangle -A PREROUTING -i l0 -p tcp --dport 80 --syn -j TCPMSS --set-mss 1360" 1448 0
check "clamping outgoing SYN-ACKs (by service source port) works around it"    base 1450 1500 blackhole "-A FORWARD -p tcp -m multiport --sports 80 -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1410" 1398 3000

echo "### Fix as proposed in #43 (tcp_fwmark_accept + SYN MARK)"
check "proposal, 1450 ingress: MSS derived from ingress route"                 proposal 1450 1500 blackhole - 1398 3000 2
check "proposal, 1550 ingress, jumbo client: MSS exceeds outside path, both directions stall" proposal 1550 9000 blackhole - 1498 "?"

echo "### Full fix (proposal + policy route MTU cap)"
for O in 1450 1500 1550 8950; do
  for C in 1500 9000; do
    case $O in 1450) E=1398;; *) E=1448;; esac
    check "fixed, ingress $O, client $C, PMTUD black hole"                   fixed $O $C blackhole - $E 3000 2
  done
done

echo
echo "Passed: $PASS  Failed: $FAIL"
[ $FAIL = 0 ]
