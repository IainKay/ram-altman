#!/usr/bin/awk -f
#
# assemble.awk - turns readable Whitespace assembly (.wsa) into Whitespace.
#
# Usage: awk -f assemble.awk ram-altman.wsa > ram-altman.ws
#
# One instruction per line. Lines starting with ; are comments.
#
#   name:                 a label
#   push 42 | push 'c' | push NAME      a number, a character or a constant
#   dup swap drop copy N slide N
#   add sub mul div mod store retrieve
#   call L  jmp L  jz L  jn L  ret end
#   outc outn readc readn
#
# Shorthands:
#   .equ NAME 42          defines a constant
#   addr x                pushes the heap address of variable x
#   ld x / st x           loads x onto the stack / stores the top of the stack in x
#   pushh "MemTotal"      pushes the hash that read_meminfo computes for a key
#   say "Hi {name}\n"     prints text; {x} calls the routine put_x
#   dispatch x pre N      jumps to label pre_<x>, for x from 0 to N-1, else returns

BEGIN {
    for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
    split("push:SS:n dup:SLS: copy:STS:n swap:SLT: drop:SLL: slide:STL:n " \
          "add:TSSS: sub:TSST: mul:TSSL: div:TSTS: mod:TSTT: " \
          "store:TTS: retrieve:TTT: " \
          "label:LSS:l call:LST:l jmp:LSL:l jz:LTS:l jn:LTT:l ret:LTL: end:LLL: " \
          "outc:TLSS: outn:TLST: readc:TLTS: readn:TLTT:", defs, " ")
    for (i in defs) {
        split(defs[i], f, ":")
        CODE[f[1]] = f[2]
        ARGK[f[1]] = f[3]
    }
    nvars = 0
    nlabels = 0
    HASH_MOD = 1000000007
}

function die(msg) {
    printf "assemble: line %d: %s\n", NR, msg > "/dev/stderr"
    failed = 1
    exit 1
}

function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
}

function bits(n,    b) {
    if (n == 0) return "S"
    b = ""
    while (n > 0) {
        b = (n % 2 ? "T" : "S") b
        n = int(n / 2)
    }
    return b
}

function number(n) {
    return (n < 0 ? "T" bits(-n) : "S" bits(n)) "L"
}

function label(name) {
    if (!(name in LABELID)) LABELID[name] = ++nlabels
    return bits(LABELID[name]) "L"
}

function out(s) {
    gsub(/S/, " ", s)
    gsub(/T/, "\t", s)
    gsub(/L/, "\n", s)
    printf "%s", s
}

function emit(name, a,    code) {
    if (!(name in CODE)) die("unknown instruction: " name)
    code = CODE[name]
    if (ARGK[name] == "n") code = code number(value(a))
    else if (ARGK[name] == "l") {
        if (a == "") die(name " needs a label")
        code = code label(a)
    }
    out(code)
}

function value(a) {
    if (a ~ /^-?[0-9]+$/) return a + 0
    if (a ~ /^'.'$/) return ORD[substr(a, 2, 1)]
    if (a in EQU) return EQU[a]
    die("not a number: " a)
}

function address(name) {
    if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) die("bad variable name: " name)
    if (!(name in VAR)) {
        VAR[name] = ++nvars
        if (nvars >= 1000) die("too many variables")
    }
    return VAR[name]
}

function unquote(s) {
    if (s !~ /^".*"$/) die("expected a quoted string: " s)
    return substr(s, 2, length(s) - 2)
}

function hash(s,    h, i) {
    h = 0
    for (i = 1; i <= length(s); i++) h = (h * 131 + ORD[substr(s, i, 1)]) % HASH_MOD
    if ((h in HASHED) && HASHED[h] != s) die("hash collision: " s " and " HASHED[h])
    HASHED[h] = s
    return h
}

function say(s,    i, c, j, len) {
    len = length(s)
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (c == "\\") {
            c = substr(s, ++i, 1)
            if (c == "n") c = "\n"
            else if (c == "t") c = "\t"
        } else if (c == "{") {
            j = index(substr(s, i), "}")
            if (!j) die("unclosed { in say")
            emit("call", "put_" substr(s, i + 1, j - 2))
            i += j - 1
            continue
        }
        emit("push", ORD[c])
        emit("outc")
    }
}

{
    line = trim($0)
    if (line == "" || line ~ /^;/) next

    if (line ~ /^[A-Za-z_][A-Za-z0-9_]*:$/) {
        name = substr(line, 1, length(line) - 1)
        if (name in DEFINED) die("label defined twice: " name)
        DEFINED[name] = 1
        emit("label", name)
        next
    }

    op = line
    rest = ""
    if (match(line, /[ \t]/)) {
        op = substr(line, 1, RSTART - 1)
        rest = trim(substr(line, RSTART))
    }

    if (op == ".equ") {
        split(rest, f, /[ \t]+/)
        EQU[f[1]] = value(f[2])
    } else if (op == "addr") {
        emit("push", address(rest))
    } else if (op == "ld") {
        emit("push", address(rest))
        emit("retrieve")
    } else if (op == "st") {
        emit("push", address(rest))
        emit("swap")
        emit("store")
    } else if (op == "pushh") {
        emit("push", hash(unquote(rest)))
    } else if (op == "say") {
        say(unquote(rest))
    } else if (op == "dispatch") {
        split(rest, f, /[ \t]+/)
        for (k = 0; k < f[3] + 0; k++) {
            emit("push", address(f[1]))
            emit("retrieve")
            emit("push", k)
            emit("sub")
            emit("jz", f[2] "_" k)
        }
        emit("ret")
    } else {
        emit(op, rest)
    }
}

END {
    if (failed) exit 1
    for (name in LABELID)
        if (!(name in DEFINED)) {
            printf "assemble: label used but never defined: %s\n", name > "/dev/stderr"
            exit 1
        }
}
