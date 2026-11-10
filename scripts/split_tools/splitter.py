import re, sys, subprocess, collections, json
from pathlib import Path

MEMBER_KW = r"(?:func|var|let|init|deinit|struct|enum|class|actor|typealias|subscript|case|extension|protocol)"
def indent(l): return len(l)-len(l.lstrip(" "))

def parse_members(L, open_idx, close_idx):
    """Members of the type body between open_idx (line with '{' opening) and close_idx (closing '}' line).
    Returns list of dicts with start,end (end exclusive) covering lines open_idx+1..close_idx."""
    starts=[]; in_str=False
    i=open_idx+1
    bodyind=indent(L[open_idx])+4 if L[open_idx].strip() else 4
    pend=None  # start of pending leading trivia
    for k in range(open_idx+1, close_idx):
        l=L[k]
        cnt=l.count('"""')
        was=in_str
        if cnt%2==1: in_str=not in_str
        if was: continue
        s=l.strip()
        if s=="" : continue
        if indent(l)==bodyind and not s.startswith(("}",")","]")):
            if s.startswith(("//","/*","*")) or re.fullmatch(r"@[\w.]+(\([^)]*\))?",s):
                if pend is None: pend=k
                continue
            starts.append(pend if pend is not None else k); pend=None
        elif indent(l)<=bodyind and not s.startswith(("}",")","]")):
            pass
    members=[]
    for n,st in enumerate(starts):
        en=starts[n+1] if n+1<len(starts) else close_idx
        members.append({"start":st,"end":en})
    return members, bodyind

def head_line(L,m,bodyind):
    for k in range(m["start"],m["end"]):
        s=L[k].strip()
        if s=="" or s.startswith("//") or s.startswith("/*") or re.fullmatch(r"@[\w.]+(\([^)]*\))?",s): continue
        return k
    return m["start"]

def classify(L,m,bodyind):
    """return 'stay' for stored props, init, body, etc; else 'move'."""
    h=head_line(L,m,bodyind); line=L[h].strip()
    text="\n".join(L[h:m["end"]])
    if re.search(r"\boverride\b|\brequired\b|\bconvenience\b",line): return "stay"
    if re.search(r"\b(init|deinit|subscript)\b\s*[(<{?]", line) and not re.search(r"\bfunc\b",line): return "stay"
    if re.search(r"\bcase\s", line) and not re.search(r"\bfunc\b",line): return "stay"
    mv=re.match(r"(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|open|final|static|class|lazy|weak|unowned|nonisolated|override|required|convenience)(?:\([^)]*\))?\s+)*(var|let)\s+(\w+|\(.*?\))",line)
    if mv:
        name=mv.group(2)
        if name=="body": return "stay"
        # computed property: first '{' follows the type annotation and no '=' before it
        before=line.split("{")[0] if "{" in line else line
        computed = ("{" in line) and ("=" not in before) and not re.search(r"\b(didSet|willSet)\b",text)
        if not computed: return "stay"
        if re.search(r"\b(didSet|willSet)\b",text): return "stay"
        return "move"
    return "move"

def declared_private_names(L,m):
    out=[]
    h=head_line(L,m,4)
    line=L[h].strip()
    mm=re.match(r"(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:final|static|class|lazy|weak|unowned|nonisolated|override|required|convenience|mutating)\s+)*(?:private|fileprivate)(?:\([^)]*\))?\s+(?:(?:final|static|class|lazy|weak|unowned|nonisolated)\s+)*(?:func|var|let|struct|enum|class|actor|typealias)\s+(\w+)",line)
    return mm.group(1) if mm else None

def split_type(src, type_decl_prefix, parts, imports, protected=(), wrap_name=None, out_dir=None, dry=False, stay_defs=()):
    """parts: list of (partname, start_line_1based, end_line_1based_exclusive); lines refer to current src file."""
    p=Path(src); L=p.read_text().split("\n")
    di=[i for i,l in enumerate(L) if l.startswith(type_decl_prefix)]; assert len(di)==1,(type_decl_prefix,di); di=di[0]
    oi=di
    while "{" not in L[oi]: oi+=1
    ci=next(i for i in range(len(L)-1,-1,-1) if L[i]=="}") if True else None
    # closing brace of the type: first col-0 "}" after open
    ci=next(i for i in range(oi+1,len(L)) if L[i]=="}")
    members,bodyind=parse_members(L,oi,ci)
    for m in members: m["class"]=classify(L,m,bodyind); m["part"]=None
    # members that define a stay_defs name stay; moved members that mention a private-protected name defined in a staying member go back
    GEN={"show","send","if","var","extractTexts","contentMenu","reset","next"}
    def defined(m):
        h=head_line(L,m,bodyind); mm=re.search(r"\b(?:func|var|let|struct|enum|class|actor|typealias)\s+(\w+)",L[h])
        return mm.group(1) if mm else None
    for m in members:
        if defined(m) in stay_defs: m["class"]="stay"
    pr_names=set()
    for m in members:
        if m["class"]=="stay":
            d=defined(m)
            if d in protected: pr_names.add(d)
    changed=True
    while changed:
        changed=False
        for m in members:
            if m["class"]!="move": continue
            text="\n".join(L[m["start"]:m["end"]])
            if any(re.search(r"\b"+re.escape(n)+(r"\(" if n in GEN else r"\b"),text) for n in pr_names):
                m["class"]="stay"; changed=True
                d=defined(m)
                if d in protected: pr_names.add(d)
    for name,a,b in parts:
        for m in members:
            if m["class"]=="move" and a-1<=m["start"]<b-1 : m["part"]=name
    typename=wrap_name or type_decl_prefix.split()[-1].rstrip(":").split(":")[0]
    keep=set(range(len(L)))
    results={}
    for name,a,b in parts:
        chunks=[]
        for m in members:
            if m["part"]==name:
                chunks.append(L[m["start"]:m["end"]])
                for k in range(m["start"],m["end"]): keep.discard(k)
        body=[]
        for c in chunks: body+=c
        while body and body[-1].strip()=="": body.pop()
        results[name]=body
    newmain=[L[i] for i in sorted(keep)]
    # collapse 3+ blank lines
    outm=[]
    for l in newmain:
        if l.strip()=="" and len(outm)>=2 and outm[-1].strip()=="" and outm[-2].strip()=="": continue
        outm.append(l)
    return L, members, results, outm, typename

def write_parts(src, results, outm, typename, imports, out_dir, dry=False):
    p=Path(src)
    outs=[]
    for name,body in results.items():
        if not body: continue
        path=Path(out_dir)/name
        txt="\n".join(imports)+"\n\nextension "+typename+" {\n"+"\n".join(body)+"\n}\n"
        outs.append((path,txt,len(body)))
        if not dry:
            path.parent.mkdir(parents=True,exist_ok=True); path.write_text(txt)
    if not dry: p.write_text("\n".join(outm))
    return outs

def type_files(main, pattern_stem, out_dir):
    return [Path(main)]+sorted(Path(out_dir).glob(pattern_stem+"+*.swift"))

def widen(files, protected=()):
    """Remove private/fileprivate (and private(set)) from member declarations whose names appear in another file of the type."""
    texts={f:Path(f).read_text() for f in files}
    decls=[]  # (file, line idx, name, kind)
    pat=re.compile(r"^(\s{4}(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:final|static|class|lazy|weak|unowned|nonisolated|override|required|mutating)\s+)*)(private|fileprivate)((?:\(set\))?)(\s+(?:(?:final|static|class|lazy|weak|unowned|nonisolated)\s+)*)(func|var|let|struct|enum|class|actor|typealias)\s+(\w+)")
    changed=collections.Counter(); skipped=[]
    for f in files:
        L=texts[f].split("\n")
        for i,l in enumerate(L):
            m=pat.match(l)
            if not m: continue
            name=m.group(6)
            used=any(re.search(r"\b"+re.escape(name)+r"\b",t) for g,t in texts.items() if g!=f)
            if not used: continue
            if name in protected: skipped.append((f,name)); continue
            if m.group(3)=="(set)":
                # keep getter visibility default: drop the modifier entirely
                L[i]=m.group(1)+m.group(4).lstrip(" ") .join(["",""]) if False else m.group(1)+m.group(5)+" "+name+l[m.end():]
                L[i]=m.group(1)+m.group(4).strip()+(" " if m.group(4).strip() else "")+m.group(5)+" "+name+l[m.end():]
            else:
                L[i]=m.group(1)+m.group(4).strip()+(" " if m.group(4).strip() else "")+m.group(5)+" "+name+l[m.end():]
            changed[str(f)]+=1
        texts[f]="\n".join(L)
    main=files[0]; L=texts[main].split("\n")
    pat0=re.compile(r"^(private|fileprivate)\s+((?:final\s+)?(?:func|let|var|struct|enum|class|actor|typealias)\s+)(\w+)")
    for i,l in enumerate(L):
        m=pat0.match(l)
        if m and any(re.search(r"\b"+re.escape(m.group(3))+r"\b",t) for g,t in texts.items() if g!=main) and m.group(3) not in protected:
            L[i]=m.group(2)+m.group(3)+l[m.end():]; changed[str(main)+" (top level)"]+=1
    texts[main]="\n".join(L)
    for f,t in texts.items(): Path(f).write_text(t)
    return changed, skipped

def fix_sigs(files):
    from sigcheck import sigcheck
    fixed=[]
    for _ in range(6):
        bad=sigcheck(files)
        if not bad: break
        names={b[2] for b in bad}
        for f in files:
            t=Path(f).read_text()
            for n in names:
                t=re.sub(r"^(\s*)(?:private|fileprivate)\s+((?:struct|enum|class|actor|typealias)\s+"+n+r"\b)",r"\1\2",t,flags=re.M)
            Path(f).write_text(t)
        fixed+=list(names)
    return fixed
