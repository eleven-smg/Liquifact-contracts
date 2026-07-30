$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$CRLF = [string][char]13 + [string][char]10
$LF   = [string][char]10
$enc  = New-Object System.Text.UTF8Encoding $false

$p = 'escrow/src/lib.rs'
$t = [IO.File]::ReadAllText((Resolve-Path $p)).Replace($CRLF, $LF)

# ---------------------------------------------------------------- anchor 1
$a1 = (@'
pub struct LegalHoldClearDelayUpdated {
    #[topic]
    pub name: Symbol,
    #[topic]
    pub invoice_id: Symbol,
    pub old_delay: u64,
    pub new_delay: u64,
}
'@).Replace($CRLF, $LF)

$e1 = (@'

/// Yield-tier table replaced by the admin.
///
/// Emitted by [`LiquifactEscrow::set_yield_tiers`] once the replacement table has passed
/// every `init`-equivalent invariant and has been written to [`DataKey::YieldTierTable`].
/// A rejected call emits nothing, so the presence of this event is a reliable signal that
/// the stored ladder actually changed.
///
/// # Fields
/// - `name`: Hardcoded `yt_upd` symbol.
/// - `invoice_id`: Invoice identifier of the escrow whose table changed.
/// - `tier_count`: Number of tiers in the newly stored table.
#[contractevent]
pub struct YieldTierTableUpdated {
    #[topic]
    pub name: Symbol,
    #[topic]
    pub invoice_id: String,
    pub tier_count: u32,
}
'@).Replace($CRLF, $LF)

# ---------------------------------------------------------------- anchor 3
$a3 = (@'
        let mut result = Vec::new(&env);
        for i in start..end {
            result.push_back(tiers.get(i).unwrap());
        }
        result
    }
'@).Replace($CRLF, $LF)

$e3 = (@'

    /// Admin-only setter that replaces the entire yield-tier ladder.
    ///
    /// Before this entrypoint existed the ladder was fixed at [`LiquifactEscrow::init`] with
    /// no update path, so correcting a mis-configured tier required redeploying the escrow.
    /// `set_yield_tiers` closes that gap while enforcing exactly the invariants `init`
    /// enforces, so no ladder reachable through this setter is unreachable through `init`.
    ///
    /// # Invariants
    ///
    /// 1. The table must be non-empty.
    /// 2. Every `yield_bps` must satisfy `0 <= yield_bps <= 10_000`.
    /// 3. `min_lock_secs` must be **strictly increasing** across tiers.
    /// 4. `yield_bps` must be **non-decreasing** across tiers.
    ///
    /// Validation runs over the whole table **before** any storage write, so a rejected
    /// call leaves the previously stored ladder byte-for-byte untouched. There is no
    /// partial application.
    ///
    /// # Authorization
    ///
    /// [`InvoiceEscrow::admin`], enforced via [`Self::load_escrow_require_admin`]. A caller
    /// without the admin authorization is rejected before any validation runs.
    ///
    /// # Errors
    ///
    /// - [`EscrowError::YieldTierTableInvalid`] (236) if any invariant above is violated.
    ///
    /// # Events
    ///
    /// Emits [`YieldTierTableUpdated`] carrying the new `tier_count` on success.
    pub fn set_yield_tiers(env: Env, tiers: Vec<YieldTier>) {
        let escrow = Self::load_escrow_require_admin(&env);

        let n = tiers.len();
        ensure(&env, n > 0, EscrowError::YieldTierTableInvalid);

        // `prev_lock` starts at 0 so the first tier must declare a positive lock, and
        // `prev_bps` starts at -1 so a first tier of 0 bps is accepted.
        let mut prev_lock: u64 = 0;
        let mut prev_bps: i64 = -1;

        for i in 0..n {
            let tier = tiers.get(i).unwrap();
            ensure(
                &env,
                tier.yield_bps >= 0,
                EscrowError::YieldTierTableInvalid,
            );
            ensure(
                &env,
                tier.yield_bps <= 10_000,
                EscrowError::YieldTierTableInvalid,
            );
            ensure(
                &env,
                tier.min_lock_secs > prev_lock,
                EscrowError::YieldTierTableInvalid,
            );
            ensure(
                &env,
                tier.yield_bps >= prev_bps,
                EscrowError::YieldTierTableInvalid,
            );
            prev_lock = tier.min_lock_secs;
            prev_bps = tier.yield_bps;
        }

        env.storage()
            .instance()
            .set(&DataKey::YieldTierTable, &tiers);

        YieldTierTableUpdated {
            name: symbol_short!("yt_upd"),
            invoice_id: escrow.invoice_id.clone(),
            tier_count: n,
        }
        .publish(&env);
    }
'@).Replace($CRLF, $LF)

# ---------------------------------------------------------------- checks
if (([regex]::Matches($t, [regex]::Escape($a1))).Count -ne 1) { throw 'anchor 1 not unique' }
if (([regex]::Matches($t, [regex]::Escape($a3))).Count -ne 1) { throw 'anchor 3 not unique' }
$m = [regex]::Match($t, '(?m)^(?<ind>[ \t]+)\w+[ \t]*=[ \t]*235,[ \t]*$')
if (-not $m.Success) { throw 'anchor 2 (discriminant 235) not found' }
if (([regex]::Matches($t, [regex]::Escape($m.Value))).Count -ne 1) { throw 'anchor 2 not unique' }
if ($t.Contains('YieldTierTableUpdated') -or $t.Contains('YieldTierTableInvalid')) { throw 'lib.rs is not pristine - run: git checkout -q upstream/main -- escrow/src/lib.rs' }

# ---------------------------------------------------------------- apply
$ind = $m.Groups['ind'].Value
$e2 = $m.Value + $LF +
      $ind + '/// The yield-tier table supplied to [`LiquifactEscrow::set_yield_tiers`] violates an' + $LF +
      $ind + '/// invariant: the table is empty, a `yield_bps` falls outside `0..=10_000`,' + $LF +
      $ind + '/// `min_lock_secs` is not strictly increasing, or `yield_bps` decreases between tiers.' + $LF +
      $ind + 'YieldTierTableInvalid = 236,'

$t = $t.Replace($a1, $a1 + $e1)
$t = $t.Replace($m.Value, $e2)
$t = $t.Replace($a3, $a3 + $e3)
[IO.File]::WriteAllText((Resolve-Path $p).Path, $t, $enc)

# ---------------------------------------------------------------- tests
$tests = (@'
#![cfg(test)]
//! Tests for the admin-guarded yield-tier setter (issue #1090).
//!
//! Coverage:
//! - an in-bounds ladder is accepted, persisted, and read back through `get_yield_tiers`
//! - each individual bound is rejected with `EscrowError::YieldTierTableInvalid`
//! - a rejected call leaves the previously stored ladder untouched
//! - a caller without admin authorization is rejected

use soroban_sdk::{testutils::Address as _, vec, Address, Env};

use super::{assert_contract_error, default_init, setup, YieldTier};
use crate::EscrowError;

/// A well-formed two-tier ladder: strictly increasing locks, non-decreasing bps, in range.
fn valid_tiers(env: &Env) -> soroban_sdk::Vec<YieldTier> {
    vec![
        env,
        YieldTier {
            min_lock_secs: 30 * 86_400,
            yield_bps: 500,
        },
        YieldTier {
            min_lock_secs: 90 * 86_400,
            yield_bps: 900,
        },
    ]
}

#[test]
fn set_yield_tiers_accepts_in_bounds_table() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    let tiers = valid_tiers(&env);
    client.set_yield_tiers(&tiers);

    let stored = client.get_yield_tiers();
    assert_eq!(stored.len(), 2);
    assert_eq!(stored.get(0).unwrap().min_lock_secs, 30 * 86_400);
    assert_eq!(stored.get(0).unwrap().yield_bps, 500);
    assert_eq!(stored.get(1).unwrap().min_lock_secs, 90 * 86_400);
    assert_eq!(stored.get(1).unwrap().yield_bps, 900);
}

#[test]
fn set_yield_tiers_replaces_the_whole_table() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    client.set_yield_tiers(&valid_tiers(&env));
    assert_eq!(client.get_yield_tiers().len(), 2);

    // A shorter ladder must replace, not merge with, the previous one.
    client.set_yield_tiers(&vec![
        &env,
        YieldTier {
            min_lock_secs: 1,
            yield_bps: 0,
        },
    ]);

    let stored = client.get_yield_tiers();
    assert_eq!(stored.len(), 1);
    assert_eq!(stored.get(0).unwrap().min_lock_secs, 1);
    assert_eq!(stored.get(0).unwrap().yield_bps, 0);
}

#[test]
fn set_yield_tiers_accepts_boundary_values() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    // yield_bps == 0 and yield_bps == 10_000 are both inclusive bounds.
    client.set_yield_tiers(&vec![
        &env,
        YieldTier {
            min_lock_secs: 1,
            yield_bps: 0,
        },
        YieldTier {
            min_lock_secs: 2,
            yield_bps: 10_000,
        },
    ]);

    let stored = client.get_yield_tiers();
    assert_eq!(stored.get(0).unwrap().yield_bps, 0);
    assert_eq!(stored.get(1).unwrap().yield_bps, 10_000);
}

#[test]
fn set_yield_tiers_rejects_empty_table() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    assert_contract_error(
        client.try_set_yield_tiers(&vec![&env]),
        EscrowError::YieldTierTableInvalid,
    );
}

#[test]
fn set_yield_tiers_rejects_yield_bps_above_max() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    assert_contract_error(
        client.try_set_yield_tiers(&vec![
            &env,
            YieldTier {
                min_lock_secs: 1,
                yield_bps: 10_001,
            },
        ]),
        EscrowError::YieldTierTableInvalid,
    );
}

#[test]
fn set_yield_tiers_rejects_negative_yield_bps() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    assert_contract_error(
        client.try_set_yield_tiers(&vec![
            &env,
            YieldTier {
                min_lock_secs: 1,
                yield_bps: -1,
            },
        ]),
        EscrowError::YieldTierTableInvalid,
    );
}

#[test]
fn set_yield_tiers_rejects_zero_first_lock() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    // prev_lock starts at 0, so the first tier must declare a strictly positive lock.
    assert_contract_error(
        client.try_set_yield_tiers(&vec![
            &env,
            YieldTier {
                min_lock_secs: 0,
                yield_bps: 100,
            },
        ]),
        EscrowError::YieldTierTableInvalid,
    );
}

#[test]
fn set_yield_tiers_rejects_non_increasing_locks() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    assert_contract_error(
        client.try_set_yield_tiers(&vec![
            &env,
            YieldTier {
                min_lock_secs: 100,
                yield_bps: 100,
            },
            YieldTier {
                min_lock_secs: 100,
                yield_bps: 200,
            },
        ]),
        EscrowError::YieldTierTableInvalid,
    );
}

#[test]
fn set_yield_tiers_rejects_decreasing_yield_bps() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    assert_contract_error(
        client.try_set_yield_tiers(&vec![
            &env,
            YieldTier {
                min_lock_secs: 100,
                yield_bps: 900,
            },
            YieldTier {
                min_lock_secs: 200,
                yield_bps: 500,
            },
        ]),
        EscrowError::YieldTierTableInvalid,
    );
}

#[test]
fn rejected_set_leaves_previous_table_intact() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    client.set_yield_tiers(&valid_tiers(&env));

    // Second tier is out of range, so the whole call must be rejected atomically.
    assert_contract_error(
        client.try_set_yield_tiers(&vec![
            &env,
            YieldTier {
                min_lock_secs: 10,
                yield_bps: 100,
            },
            YieldTier {
                min_lock_secs: 20,
                yield_bps: 10_001,
            },
        ]),
        EscrowError::YieldTierTableInvalid,
    );

    let stored = client.get_yield_tiers();
    assert_eq!(stored.len(), 2);
    assert_eq!(stored.get(0).unwrap().yield_bps, 500);
    assert_eq!(stored.get(1).unwrap().yield_bps, 900);
}

#[test]
fn set_yield_tiers_rejects_non_admin_caller() {
    let env = Env::default();
    let (client, admin, sme) = setup(&env);
    default_init(&client, &env, &admin, &sme);

    let _intruder = Address::generate(&env);

    // Drop every mocked authorization so the admin require_auth gate is actually exercised.
    env.set_auths(&[]);

    let result = client.try_set_yield_tiers(&valid_tiers(&env));
    assert!(
        result.is_err(),
        "set_yield_tiers must reject a caller lacking admin authorization"
    );

    // And the ladder configured at init must be unchanged.
    env.mock_all_auths();
    assert!(client.get_yield_tiers().is_empty());
}
'@).Replace($CRLF, $LF)

[IO.File]::WriteAllText((Join-Path (Get-Location) 'escrow/src/tests/yield_tier_setter.rs'), $tests, $enc)

Write-Host '--- patch applied ---'
git --no-pager diff --stat
Write-Host '--- anchors landed ---'
Select-String -Path $p -Pattern 'YieldTierTableInvalid = 236|pub struct YieldTierTableUpdated|pub fn set_yield_tiers'
