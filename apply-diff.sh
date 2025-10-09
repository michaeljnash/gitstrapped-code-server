#!/usr/bin/env sh
# apply-diff.sh — whitespace-tolerant, subsequence-anchored patch applier
# Usage: ./apply-diff.sh <target-file> <anchored.patch>
set -eu

fatal(){ printf '%s\n' "ERROR: $*" >&2; exit 2; }
need(){ command -v "$1" >/dev/null 2>&1 || fatal "missing dependency: $1"; }

[ $# -eq 2 ] || fatal "usage: $0 <target-file> <anchored.patch>"
TGT="$1"; PATCH="$2"
[ -f "$TGT" ]   || fatal "target not found: $TGT"
[ -f "$PATCH" ] || fatal "patch not found: $PATCH"
need awk; need sed; need date; need mktemp

BKP="${TGT}.bak.$(date +%Y%m%d-%H%M%S)"
cp -f "$TGT" "$BKP"
echo "Backup: $BKP"

# --- Parse anchored patch into hunks with OLD/NEW blocks and weak ctx anchors ---
HUNKS_FILE="$(mktemp)"; : >"$HUNKS_FILE"
awk '
  BEGIN{inh=0; o=0; n=0; ctxb=""; ctxa=""}
  function flush(){
    if(!inh) return
    print "---HUNK---"
    print "OLD:"
    for(i=1;i<=o;i++) print old[i]
    print "NEW:"
    for(i=1;i<=n;i++) print neu[i]
    print "CTX_BEFORE:"; print ctxb
    print "CTX_AFTER:";  print ctxa
    inh=0; o=0; n=0; delete old; delete neu; ctxb=""; ctxa=""
  }
  /^@@[[:space:]]*$/ { flush(); inh=1; next }
  {
    if(!inh) next
    L=$0
    if(L ~ /^-/){ sub(/^-/, "", L); old[++o]=L }
    else if(L ~ /^\+/){ sub(/^\+/, "", L); neu[++n]=L }
    else { t=L; gsub(/^[ \t]+|[ \t]+$/,"",t); gsub(/[ \t][ \t]+/," ",t); if(t!=""){ if(ctxb=="") ctxb=t; ctxa=t } }
  }
  END{ flush() }
' "$PATCH" >> "$HUNKS_FILE"

norm_stream(){ sed -e 's/[[:space:]]\+$//' -e 's/^[[:space:]]\+//' -e 's/[[:space:]][[:space:]]\+/ /g'; }

# --- Hunk applier with exact OR subsequence match + context scoring ---
apply_hunk(){
  tgt="$1"; out="$2"; ofile="$3"; nfile="$4"; ctxb="$5"; ctxa="$6"

  # No-op? (OLD == NEW after normalization)
  onorm="$(norm_stream < "$ofile")"
  nnorm="$(norm_stream < "$nfile")"
  if [ "$onorm" = "$nnorm" ]; then
    echo "SKIP: no-op hunk"
    cp -f "$tgt" "$out"
    return 0
  fi

  # Pure insertion?
  if [ ! -s "$ofile" ]; then
    awk -v OFS="" \
        -v ctxb="$(printf '%s' "$ctxb" | norm_stream)" \
        -v ctxa="$(printf '%s' "$ctxa" | norm_stream)" \
        -v NFILE="$nfile" '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      function norm(s){ s=trim(s); gsub(/[ \t][ \t]+/," ",s); return s }
      BEGIN{
        R=0; while((getline L)<ARGV[1]){ raw[++R]=L; NL[R]=norm(L) } delete ARGV[1]
        ins=R+1
        if(ctxb!=""){ for(i=R;i>=1;i--) if(NL[i]==ctxb){ ins=i+1; break } }
        if(ctxa!=""){ for(i=1;i<=R;i++) if(NL[i]==ctxa){ if(i<ins) ins=i; break } }
        for(i=1;i<ins;i++) print raw[i]
        while((getline M < NFILE)>0) print M; close(NFILE)
        for(i=ins;i<=R;i++) print raw[i]
      }
    ' "$tgt" > "$out" || return $?
    return 0
  fi

  # Replacement (exact window, else subsequence)
  awk -v OFS="" \
      -v OFILE="$ofile" -v NFILE="$nfile" \
      -v ctxb="$(printf '%s' "$ctxb" | norm_stream)" \
      -v ctxa="$(printf '%s' "$ctxa" | norm_stream)" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    function norm(s){ s=trim(s); gsub(/[ \t][ \t]+/," ",s); return s }
    function load_block_norm(file,  l,ln){
      len=0
      while((getline l < file)>0){ ln=norm(l); if(ln!=""){ B[++len]=ln } else { B[++len]="" } }
      close(file); return len
    }
    function load_block_raw(file,  l){
      rlen=0; while((getline l < file)>0){ R[++rlen]=l } close(file); return rlen
    }
    function compute_exact(NL,N, O,olen,  s,j,ok,score,bi,ai){
      best=-1; bc=0
      for(s=1;s<=N-olen+1;s++){
        ok=1; for(j=1;j<=olen;j++) if(NL[s+j-1]!=O[j]){ ok=0; break }
        if(!ok) continue
        score=0
        if(ctxb!=""){ bi=s-1; if(bi>=1 && NL[bi]==ctxb) score+=2 }  # heavy weight for ctx
        if(ctxa!=""){ ai=s+olen; if(ai<=N && NL[ai]==ctxa) score+=2 }
        winlen=olen
        # prefer exact blocks (shortest span by definition); add small bias
        score+=1
        EXS[++bc]=s; EXSCORE[bc]=score
        if(score>best) best=score
      }
      if(bc==0) return 0
      # keep best(s)
      kept=0
      for(i=1;i<=bc;i++) if(EXSCORE[i]==best) K[++kept]=EXS[i]
      if(kept==1){ MATCH_TYPE="exact"; MATCH_S=K[1]; return 1 }
      # tie → ambiguous for exact, but we will let subsequence try to disambiguate
      return 0
    }
    function compute_subseq(NL,N, O,olen, mapN,  s,i,j,pos,first,last,score,span,found){
      best=-1; cand=0
      for(s=1;s<=N;s++){
        pos=s-1; first=0; last=0; found=1
        for(j=1;j<=olen;j++){
          # advance until we find O[j]
          i=pos+1
          while(i<=N && NL[i]!=O[j]) i++
          if(i>N){ found=0; break }
          if(first==0) first=i
          last=i
          pos=i
        }
        if(!found) break
        # score: anchors + density (olen/span)
        span = (last-first+1)
        score = 0
        if(ctxb!="" && first>1 && NL[first-1]==ctxb) score+=2
        if(ctxa!="" && last<N  && NL[last+1]==ctxa)  score+=2
        score += (olen*1000)/span    # prefer tightest span
        SS[++cand]=first; EE[cand]=last; SC[cand]=score
        if(score>best) best=score
      }
      if(cand==0) return 0
      kept=0
      for(i=1;i<=cand;i++) if(SC[i]==best){ K1[++kept]=SS[i]; K2[kept]=EE[i] }
      if(kept!=1) { return -1 }  # ambiguous
      MATCH_TYPE="subseq"; MATCH_FIRST=K1[1]; MATCH_LAST=K2[1]; return 1
    }

    BEGIN{
      # Load OLD (normalized) + NEW (raw)
      olen=load_block_norm(OFILE)
      nlen_raw=load_block_raw(NFILE)

      # Normalize NEW as well (for idempotency check)
      nlen=0; for(i=1;i<=nlen_raw;i++){ NRML[++nlen]=norm(R[i]) }

      # Load target (raw + normalized with index map)
      Rlen=0; Nlen=0
      while((getline line < ARGV[1])>0){
        RAW[++Rlen]=line
        NL[++Nlen]=norm(line)
        MAP[Nlen]=Rlen
      }
      delete ARGV[1]

      if(Rlen==0){ print "FAIL: target empty" >"/dev/stderr"; exit 55 }

      # Idempotent check: if NEW already present as a contiguous normalized block, skip
      if(nlen>0){
        for(s=1;s<=Nlen-nlen+1;s++){
          ok=1; for(j=1;j<=nlen;j++) if(NL[s+j-1]!=NRML[j]){ ok=0; break }
          if(ok){
            print "SKIP: already applied" >"/dev/stderr"
            for(i=1;i<=Rlen;i++) print RAW[i]
            exit 0
          }
        }
      }

      # 1) Exact normalized window
      if( compute_exact(NL,Nlen, B,olen) ){
        s=MATCH_S; first=MAP[s]; last=MAP[s+olen-1]
      } else {
        # 2) Subsequence (ordered, gaps allowed), densest span + ctx anchors
        r=compute_subseq(NL,Nlen, B,olen, MAP)
        if(r==0){ print "FAIL: no fuzzy match for hunk" >"/dev/stderr"; exit 52 }
        if(r<0){  print "AMBIGUOUS: multiple fuzzy candidates; add more unchanged context." >"/dev/stderr"; exit 53 }
        first=MAP[MATCH_FIRST]; last=MAP[MATCH_LAST]
      }

      # Write output: before OLD-span, NEW raw, after OLD-span
      for(i=1;i<first;i++) print RAW[i]
      for(i=1;i<=nlen_raw;i++) print R[i]
      for(i=last+1;i<=Rlen;i++) print RAW[i]
    }
  ' "$tgt" > "$out" || return $?

  return 0
}

# --- Drive all hunks ---
H=0; OK=0; FAIL=0
exec 3<"$HUNKS_FILE"
while :; do
  IFS= read -r hdr <&3 || break
  [ "$hdr" = "---HUNK---" ] || continue
  read -r _ <&3 || true # OLD:
  O_TMP="$(mktemp)"; : > "$O_TMP"
  while IFS= read -r L <&3 && [ "$L" != "NEW:" ]; do printf '%s\n' "$L" >> "$O_TMP"; done
  N_TMP="$(mktemp)"; : > "$N_TMP"
  while IFS= read -r L <&3 && [ "$L" != "CTX_BEFORE:" ]; do printf '%s\n' "$L" >> "$N_TMP"; done
  read -r CTXB <&3 || true
  read -r _    <&3 || true # CTX_AFTER:
  read -r CTXA <&3 || true

  H=$((H+1)); echo "HUNK #$H…"
  TMP_OUT="$(mktemp)"
  if apply_hunk "$TGT" "$TMP_OUT" "$O_TMP" "$N_TMP" "$CTXB" "$CTXA"; then
    if [ ! -s "$TMP_OUT" ]; then
      echo "FAIL: guard — empty output; leaving original intact." >&2
      rm -f "$TMP_OUT" "$O_TMP" "$N_TMP"
      FAIL=$((FAIL+1))
      continue
    fi
    mv -f "$TMP_OUT" "$TGT"; OK=$((OK+1))
  else
    rm -f "$TMP_OUT" 2>/dev/null || true
    FAIL=$((FAIL+1))
  fi
  rm -f "$O_TMP" "$N_TMP" 2>/dev/null || true
done
exec 3<&-

rm -f "$HUNKS_FILE" 2>/dev/null || true
echo "Done: applied=$OK failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
