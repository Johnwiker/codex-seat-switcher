"""Codex seat sync: copy the project/group sidebar layout (not threads) from one
Codex workspace seat to every other seat stored on this PC.

Commands:
  status                       list seats and their layout
  sync --from <seat> [--yes]   copy that seat's layout to all other seats
  sync --from <seat> --dry-run show what would change, write nothing
  restore <backup-file>        put a backup back

<seat> is "active" or the first characters of a seat id shown by `status`.
Use --home <dir> to work on a copy of the .codex folder instead of the real one.
"""
import argparse, copy, datetime, hashlib, json, os, shutil, subprocess, sys

STATE = ".codex-global-state.json"
ACC_KEY = "electron-account-renderer-state-v1"
ATOMS = "electron-persisted-atom-state"

# Layout = groups (A) + projects (B). Threads (C) are deliberately left out.
GLOBAL_KEYS = [
    "local-projects", "project-order", "project-appearances",
    "app-server-project-id-by-legacy-project-id-by-host",
    "electron-saved-workspace-roots",
]
ATOM_KEYS = [
    "sidebar-custom-sections-v3",          # groups; keyed by account id
    "unified-sidebar-project-order-v1",
    "sidebar-project-list-expanded-v1",
    "flat-project-sidebar-preferences-v1",
]
ATOM_PREFIXES = ["sidebar-project-expanded-v1-codex:"]
ACCOUNT_KEYED = {"sidebar-custom-sections-v3"}
MAX_REMOVALS_WITHOUT_YES = 2

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
SYNC_RECORD = os.path.join(TOOL_DIR, "last_sync.json")
BACKUP_DIR = os.path.join(TOOL_DIR, "backups")
LOGIN_DIR = os.path.join(TOOL_DIR, "logins")


class Abort(Exception):
    pass


# ---------- reading the state file ----------
def load(home):
    path = os.path.join(home, STATE)
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    acc = d.get(ACC_KEY)
    if not (isinstance(acc, dict) and "owner" in acc and isinstance(acc.get("inactive"), dict)
            and isinstance(d.get(ATOMS), dict)):
        raise Abort("Unknown Codex state format (maybe after an update). Nothing changed.")
    for o, v in acc["inactive"].items():
        if not (isinstance(v, dict) and isinstance(v.get("atoms"), dict) and isinstance(v.get("globals"), dict)):
            raise Abort(f"Parked seat {o[:8]} has an unknown format. Nothing changed.")
    return d


def seats(d):
    """Return {owner_id: (atoms_dict, globals_dict, is_active)} as live references."""
    acc = d[ACC_KEY]
    out = {acc["owner"]: (d[ATOMS], d, True)}
    for o, v in acc["inactive"].items():
        out[o] = (v["atoms"], v["globals"], False)
    return out


def account_id(atoms):
    return (atoms.get("electron:last-switched-workspace") or {}).get("accountId")


def layout(atoms, glob):
    lay = {"globals": {k: glob.get(k) for k in GLOBAL_KEYS if k in glob},
           "atoms": {k: atoms.get(k) for k in ATOM_KEYS if k in atoms}}
    for k in atoms:
        if any(k.startswith(p) for p in ATOM_PREFIXES):
            lay["atoms"][k] = atoms[k]
    sec = lay["atoms"].get("sidebar-custom-sections-v3")
    if isinstance(sec, dict) and len(sec) == 1:      # compare groups independent of account id
        lay["atoms"]["sidebar-custom-sections-v3"] = {"*": next(iter(sec.values()))}
    return lay


def digest(lay):
    return hashlib.sha256(json.dumps(lay, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]


def projects(glob):
    lp = glob.get("local-projects") or {}
    return {pid: (p.get("name") if isinstance(p, dict) else str(p)) for pid, p in lp.items()}


def groups(atoms):
    sec = atoms.get("sidebar-custom-sections-v3") or {}
    names = []
    for v in sec.values():
        for s in (v or {}).get("sections", []):
            names.append(s.get("name") or s.get("title") or s.get("id") if isinstance(s, dict) else str(s))
    return names


def find_seat(all_seats, key):
    if key == "active":
        return next(o for o, s in all_seats.items() if s[2])
    hits = [o for o in all_seats if o.startswith(key)]
    if len(hits) != 1:
        raise Abort(f"Seat '{key}' matches {len(hits)} seats. Use `status` to see ids.")
    return hits[0]


# ---------- safety ----------
def codex_running():
    """True if the Codex app window (ChatGPT.exe from the OpenAI.Codex package) or codex.exe runs."""
    ps = ("Get-Process | Where-Object { $_.Name -eq 'codex' -or "
          "($_.Path -and $_.Path -like '*\\WindowsApps\\OpenAI.Codex_*') } | Select-Object -First 1 -ExpandProperty Id")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return True   # cannot tell -> be safe and assume it is running
    return bool(out)


def read_record():
    try:
        with open(SYNC_RECORD, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def backup(home, label):
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = os.path.join(BACKUP_DIR, f"{stamp}-{label}{STATE}")
    shutil.copy2(os.path.join(home, STATE), dst)
    return dst


def write_state(home, d):
    path = os.path.join(home, STATE)
    tmp = path + ".seat-sync.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    with open(tmp, encoding="utf-8") as f:
        json.load(f)                      # verify it parses before replacing
    os.replace(tmp, path)
    shutil.copy2(path, path + ".bak")     # Codex keeps an identical .bak


# ---------- commands ----------
def cmd_status(home):
    d = load(home)
    rec = read_record()
    for o, (atoms, glob, active) in seats(d).items():
        lay = layout(atoms, glob)
        h = digest(lay)
        changed = rec.get("hash") and h != rec["hash"]
        print(f"{'*' if active else ' '} seat {o[:10]}  account {str(account_id(atoms))[:8]}  "
              f"projects={len(projects(glob))} groups={len(groups(atoms))}  layout={h}"
              f"{'  (changed since last sync)' if changed else ''}")
    print("* = seat Codex will open with")


def apply_layout(src, dst, src_acc, dst_acc):
    s_atoms, s_glob, _ = src
    d_atoms, d_glob, _ = dst
    for k in GLOBAL_KEYS:
        if k in s_glob:
            d_glob[k] = copy.deepcopy(s_glob[k])
        else:
            d_glob.pop(k, None)
    for k in list(d_atoms):
        if any(k.startswith(p) for p in ATOM_PREFIXES):
            del d_atoms[k]
    keys = ATOM_KEYS + [k for k in s_atoms if any(k.startswith(p) for p in ATOM_PREFIXES)]
    for k in keys:
        if k not in s_atoms:
            d_atoms.pop(k, None)
            continue
        val = copy.deepcopy(s_atoms[k])
        if k in ACCOUNT_KEYED and isinstance(val, dict) and len(val) == 1 and dst_acc:
            val = {dst_acc: next(iter(val.values()))}
        d_atoms[k] = val


def cmd_sync(home, src_key, dry, yes, real):
    if real and not dry and codex_running():
        raise Abort("Codex is running. Close Codex completely, then run sync again.")
    d = load(home)
    all_seats = seats(d)
    src_id = find_seat(all_seats, src_key)
    src = all_seats[src_id]
    src_lay = layout(src[0], src[1])
    src_proj = projects(src[1])
    rec = read_record()
    plan, warnings = [], []
    for o, dst in all_seats.items():
        if o == src_id:
            continue
        before = projects(dst[1])
        removed = sorted(set(before.values()) - set(src_proj.values()))
        added = sorted(set(src_proj.values()) - set(before.values()))
        g_rem = sorted(set(groups(dst[0])) - set(groups(src[0])))
        g_add = sorted(set(groups(src[0])) - set(groups(dst[0])))
        dst_hash = digest(layout(dst[0], dst[1]))
        is_new_seat = not before and not groups(dst[0])
        if rec.get("hash") and not is_new_seat and dst_hash != rec["hash"] and dst_hash != digest(src_lay):
            warnings.append(f"seat {o[:10]} was edited since the last sync; its edits will be replaced")
        if len(removed) + len(g_rem) > MAX_REMOVALS_WITHOUT_YES:
            warnings.append(f"seat {o[:10]} would lose {len(removed)} projects and {len(g_rem)} groups")
        plan.append((o, dst, added, removed, g_add, g_rem))

    print(f"Source: seat {src_id[:10]} ({len(src_proj)} projects, {len(groups(src[0]))} groups)")
    for o, _, a, r, ga, gr in plan:
        if not (a or r or ga or gr):
            print(f"  seat {o[:10]}: projects/groups already match (order/expand state still copied)")
        else:
            print(f"  seat {o[:10]}: +{len(a)} projects {a}  -{len(r)} projects {r}  +groups {ga}  -groups {gr}")
    for w in warnings:
        print("  WARNING:", w)
    if dry:
        print("Dry run: nothing written.")
        return
    if warnings and not yes:
        raise Abort("Stopped because of the warnings above. Re-run with --yes if this is what you want.")

    bk = backup(home, "before-sync-")
    src_acc = account_id(src[0])
    for o, dst, *_ in plan:
        apply_layout(src, dst, src_acc, account_id(dst[0]))
    write_state(home, d)
    with open(SYNC_RECORD, "w", encoding="utf-8") as f:
        json.dump({"hash": digest(src_lay), "at": datetime.datetime.now().isoformat(timespec="seconds"),
                   "home": os.path.abspath(home)}, f, indent=1)
    print(f"Synced. Backup: {bk}")


def _find_rate_limits(o):
    if isinstance(o, dict):
        if isinstance(o.get("rate_limits"), dict):
            return o["rate_limits"]
        for v in o.values():
            r = _find_rate_limits(v)
            if r:
                return r
    return None


def last_usage_by_account(home, max_files_per_account=15):
    """Latest recorded Codex usage per account, read from the tail of recent session logs."""
    import sqlite3
    out = {}
    try:
        c = sqlite3.connect(f"file:{os.path.join(home, 'state_5.sqlite')}?mode=ro", uri=True)
        rows = c.execute("select creator_account_id, rollout_path from threads "
                         "where creator_account_id is not null and rollout_path != '' "
                         "order by updated_at_ms desc").fetchall()
    except Exception:
        return out
    tried = {}
    for acc, path in rows:
        if acc in out or tried.get(acc, 0) >= max_files_per_account or not os.path.exists(path):
            continue
        tried[acc] = tried.get(acc, 0) + 1
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 512 * 1024))
            lines = f.read().decode("utf-8", "ignore").splitlines()
        for line in reversed(lines):
            if '"rate_limits"' in line and '"used_percent"' in line:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                rl = _find_rate_limits(o)
                if rl and rl.get("primary"):
                    p = rl["primary"]
                    out[acc] = {"used_percent": p.get("used_percent"), "window_minutes": p.get("window_minutes"),
                                "resets_at": p.get("resets_at"), "seen": o.get("timestamp"),
                                "credits": rl.get("credits"), "plan": rl.get("plan_type"),
                                "limit_reached": rl.get("rate_limit_reached_type"),
                                "spend_cap": rl.get("spend_control_reached")}
                    break
    return out


def cmd_seats(home):
    d = load(home)
    usage = last_usage_by_account(home)
    out = []
    for o, (atoms, glob, active) in seats(d).items():
        acc = account_id(atoms)
        out.append({"owner": o, "account": acc, "active": active, "projects": len(projects(glob)),
                    "groups": len(groups(atoms)), "usage": usage.get(acc), "slot": slot_info(acc)})
    print(json.dumps(out))


# ---------- seat switching by login slots ----------
# All seats share one login (same refresh token). A workspace switch only changes
# tokens.account_id and tokens.access_token. So we keep the CURRENT login file
# (newest refresh token) and plant only the target seat's account_id + access_token.
# An old refresh token is never written back.

def _jwt_exp(tok):
    import base64
    try:
        p = tok.split(".")[1]
        p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p)).get("exp")
    except Exception:
        return None


def _read_login(path):
    with open(path, encoding="utf-8") as f:
        a = json.load(f)
    t = a.get("tokens") if isinstance(a, dict) else None
    if not (isinstance(t, dict) and t.get("account_id") and t.get("access_token") and t.get("refresh_token")):
        raise Abort("Codex login file has an unknown format. Nothing changed.")
    return a


def save_current_login(home):
    """Copy the current login file into its seat's slot. Returns the seat id."""
    a = _read_login(os.path.join(home, "auth.json"))
    os.makedirs(LOGIN_DIR, exist_ok=True)
    acc = a["tokens"]["account_id"]
    _write_json(os.path.join(LOGIN_DIR, acc + ".json"), a)
    return acc


def _write_json(path, obj):
    tmp = path + ".seat-sync.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
    with open(tmp, encoding="utf-8") as f:
        json.load(f)
    os.replace(tmp, path)


def slot_info(acc):
    p = os.path.join(LOGIN_DIR, f"{acc}.json")
    if not acc or not os.path.exists(p):
        return None
    try:
        t = _read_login(p)["tokens"]
    except Abort:
        return None
    return {"access_expires": _jwt_exp(t["access_token"])}


def cmd_switch(home, target, real):
    """Exit 0 = switched/already there, 4 = no saved login for that seat yet."""
    if real and codex_running():
        raise Abort("Codex is running. Close Codex completely, then switch.")
    auth = os.path.join(home, "auth.json")
    cur = _read_login(auth)
    cur_acc = save_current_login(home)
    if target == cur_acc:
        print("ALREADY: Codex is already signed in to this seat.")
        return 0
    slot = os.path.join(LOGIN_DIR, target + ".json")
    if not os.path.exists(slot):
        print("NO_SLOT: no saved login for this seat yet. Switch once in Codex's menu; "
              "the picker saves it automatically next time.")
        return 4
    tgt = _read_login(slot)["tokens"]
    if tgt.get("login_owner_id") != cur["tokens"].get("login_owner_id"):
        raise Abort("The saved login for this seat belongs to a different sign-in. Not switched.")
    exp = _jwt_exp(tgt["access_token"])
    expired = exp is not None and exp < datetime.datetime.now().timestamp()
    bdir = os.path.join(LOGIN_DIR, "auth-backups")
    os.makedirs(bdir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(auth, os.path.join(bdir, f"auth-{stamp}.json"))
    for old in sorted(os.listdir(bdir))[:-10]:          # keep the last 10 backups
        os.remove(os.path.join(bdir, old))
    new = json.loads(json.dumps(cur))
    new["tokens"]["account_id"] = tgt["account_id"]
    new["tokens"]["access_token"] = tgt["access_token"]
    _write_json(auth, new)
    print("SWITCHED" + (" (EXPIRED access token: Codex will renew it and may land in another seat)" if expired else ""))
    return 0


def cmd_restore(home, file, real):
    if real and codex_running():
        raise Abort("Codex is running. Close Codex completely, then restore.")
    with open(file, encoding="utf-8") as f:
        json.load(f)
    backup(home, "before-restore-")
    shutil.copy2(file, os.path.join(home, STATE))
    shutil.copy2(file, os.path.join(home, STATE + ".bak"))
    print("Restored", file)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--home", default=os.path.expanduser("~/.codex"))
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("seats")
    w = sub.add_parser("switch")
    w.add_argument("--to", required=True, help="full seat (account) id")
    s = sub.add_parser("sync")
    s.add_argument("--from", dest="src", required=True)
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--yes", action="store_true")
    r = sub.add_parser("restore")
    r.add_argument("file")
    a = p.parse_args()
    real = os.path.abspath(a.home) == os.path.abspath(os.path.expanduser("~/.codex"))
    global SYNC_RECORD, BACKUP_DIR, LOGIN_DIR
    if not real:   # keep test runs away from the real sync record, backups and login slots
        SYNC_RECORD = os.path.join(a.home, "last_sync.test.json")
        BACKUP_DIR = os.path.join(a.home, "backups")
        LOGIN_DIR = os.path.join(a.home, "logins")
    try:
        if a.cmd == "status":
            cmd_status(a.home)
        elif a.cmd == "seats":
            cmd_seats(a.home)
        elif a.cmd == "switch":
            sys.exit(cmd_switch(a.home, a.to, real))
        elif a.cmd == "sync":
            cmd_sync(a.home, a.src, a.dry_run, a.yes, real)
        else:
            cmd_restore(a.home, a.file, real)
    except Abort as e:
        print("STOPPED:", e)
        sys.exit(2)


if __name__ == "__main__":
    main()
