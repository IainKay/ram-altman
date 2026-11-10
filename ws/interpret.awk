#!/usr/bin/awk -f
#
# interpret.awk - a small Whitespace interpreter, so ram-altman needs nothing
# you don't already have. Any standard interpreter (such as the original
# wspace) runs ram-altman.ws just as well.
#
# Usage: awk -f interpret.awk program.ws < input
#
# Run it with LC_ALL=C so characters are read and written as plain bytes.

BEGIN {
    if (ARGC < 2) fail("usage: awk -f interpret.awk program.ws")
    for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i

    load(ARGV[1])
    parse()
    run()
}

function fail(msg) {
    printf "whitespace: %s\n", msg > "/dev/stderr"
    exit 1
}

# Keeps the only three characters Whitespace reads: space, tab and newline.
function load(file,    line, r, i, c, len) {
    nt = 0
    while ((r = (getline line < file)) > 0) {
        len = length(line)
        for (i = 1; i <= len; i++) {
            c = substr(line, i, 1)
            if (c == " ") tok[++nt] = "S"
            else if (c == "\t") tok[++nt] = "T"
        }
        tok[++nt] = "L"
    }
    if (r < 0) fail("cannot read " file)
}

function parse(    c, kind, defs, f, i) {
    split("SS:push:n SLS:dup: STS:copy:n SLT:swap: SLL:drop: STL:slide:n " \
          "TSSS:add: TSST:sub: TSSL:mul: TSTS:div: TSTT:mod: " \
          "TTS:store: TTT:retrieve: " \
          "LSS:label:l LST:call:l LSL:jmp:l LTS:jz:l LTT:jn:l LTL:ret: LLL:end: " \
          "TLSS:outc: TLST:outn: TLTS:readc: TLTT:readn:", defs, " ")
    for (i in defs) {
        split(defs[i], f, ":")
        OPNAME[f[1]] = f[2]
        OPARG[f[1]] = f[3]
    }

    ni = 0
    pos = 1
    c = ""
    while (pos <= nt) {
        c = c tok[pos++]
        if (!(c in OPNAME)) {
            if (length(c) >= 4) fail("unknown instruction at token " pos)
            continue
        }
        op[++ni] = OPNAME[c]
        kind = OPARG[c]
        if (kind == "n") arg[ni] = number()
        else if (kind == "l") arg[ni] = labelname()
        if (op[ni] == "label") {
            if (arg[ni] in LABEL) fail("label defined twice")
            LABEL[arg[ni]] = ni
        }
        c = ""
    }
}

function number(    sign, v, t) {
    sign = tok[pos++]
    v = 0
    while (pos <= nt && (t = tok[pos++]) != "L") v = v * 2 + (t == "T")
    return sign == "T" ? -v : v
}

function labelname(    s, t) {
    s = "."
    while (pos <= nt && (t = tok[pos++]) != "L") s = s t
    return s
}

function need(n) {
    if (sp < n) fail("stack underflow at instruction " (pc - 1) " (" op[pc - 1] ")")
}

function jump(l) {
    if (!(l in LABEL)) fail("jump to a label that does not exist")
    pc = LABEL[l]
}

# Floor division, as in the reference interpreter.
function fdiv(a, b,    q) {
    if (b == 0) fail("division by zero")
    q = int(a / b)
    if (q * b != a && (a < 0) != (b < 0)) q--
    return q
}

# Makes sure an input line is buffered, newline included. 0 at end of input.
function fill() {
    if (inpos <= inlen) return 1
    if ((getline inbuf < "/dev/stdin") <= 0) return 0
    inbuf = inbuf "\n"
    inlen = length(inbuf)
    inpos = 1
    return 1
}

function run(    o, a, b, t) {
    pc = 1; sp = 0; csp = 0
    inpos = 1; inlen = 0
    for (;;) {
        if (pc > ni) fail("program ran off the end without an end instruction")
        o = op[pc]; a = arg[pc]; pc++

        if (o == "push") st[++sp] = a
        else if (o == "outc") { need(1); printf "%c", st[sp--] }
        else if (o == "retrieve") { need(1); st[sp] = (st[sp] in heap) ? heap[st[sp]] : 0 }
        else if (o == "store") { need(2); heap[st[sp - 1]] = st[sp]; sp -= 2 }
        else if (o == "swap") { need(2); t = st[sp]; st[sp] = st[sp - 1]; st[sp - 1] = t }
        else if (o == "add") { need(2); b = st[sp--]; st[sp] += b }
        else if (o == "sub") { need(2); b = st[sp--]; st[sp] -= b }
        else if (o == "mul") { need(2); b = st[sp--]; st[sp] *= b }
        else if (o == "div") { need(2); b = st[sp--]; st[sp] = fdiv(st[sp], b) }
        else if (o == "mod") { need(2); b = st[sp--]; st[sp] -= b * fdiv(st[sp], b) }
        else if (o == "jz") { need(1); if (st[sp--] == 0) jump(a) }
        else if (o == "jn") { need(1); if (st[sp--] < 0) jump(a) }
        else if (o == "jmp") jump(a)
        else if (o == "call") { cs[++csp] = pc; jump(a) }
        else if (o == "ret") { if (csp == 0) fail("return outside a call"); pc = cs[csp--] }
        else if (o == "label") continue
        else if (o == "dup") { need(1); st[sp + 1] = st[sp]; sp++ }
        else if (o == "drop") { need(1); sp-- }
        else if (o == "copy") {
            if (a < 0 || a >= sp) fail("copy reaches past the bottom of the stack")
            st[sp + 1] = st[sp - a]; sp++
        }
        else if (o == "slide") {
            need(1)
            if (a > sp - 1) a = sp - 1
            t = st[sp]; sp -= a; st[sp] = t
        }
        else if (o == "outn") { need(1); printf "%.0f", st[sp--] }
        else if (o == "readc") {
            need(1)
            heap[st[sp--]] = fill() ? ORD[substr(inbuf, inpos++, 1)] + 0 : -1
        }
        else if (o == "readn") {
            need(1)
            if (fill()) {
                t = substr(inbuf, inpos)
                sub(/\n$/, "", t)
                inpos = inlen + 1
                heap[st[sp--]] = t + 0
            } else heap[st[sp--]] = -1
        }
        else if (o == "end") exit 0
    }
}
