//! Issue #1394: sustained single-proposer stress test for the pending
//! parameter-proposal queue.
//!
//! `test_parameter_governance.rs` seeds a full queue directly and checks the
//! cap once. This suite instead drives the queue through the public entry
//! point from one authorized proposer, repeatedly, well past saturation, and
//! checks the documented policy (reject at `MAX_PENDING_PARAMETER_PROPOSALS`,
//! prune expired entries, never grow unbounded), FIFO ordering, and the cost
//! of proposing/listing at saturation. See `docs/governance-queue-stress.md`.

use soroban_sdk::{
    testutils::{Address as _, Ledger as _},
    Address, Bytes, Env, Vec,
};

use crate::{
    constants::{
        DEFAULT_UPGRADE_DELAY_SECS, MAX_PENDING_PARAMETER_PROPOSALS, MIN_COOLDOWN_SECS,
    },
    parameter_governance::param_key_cooldown,
    types::ParameterProposalStatus,
    Error, LedgerLensScoreContract, LedgerLensScoreContractClient,
};

const START_TS: u64 = 1_700_000_000;
const ROUNDS: u64 = 4;
/// Attempts per round: well past the queue cap.
const ATTEMPTS_PER_ROUND: u32 = MAX_PENDING_PARAMETER_PROPOSALS * 3;
/// Worst-case CPU budget (soroban test-env instructions) for a single
/// `propose_parameter_change` or `get_pending_param_prop_ids` call at
/// saturation. Documented in `docs/governance-queue-stress.md`.
const MAX_CPU_AT_SATURATION: u64 = 2_000_000;

fn setup<'a>() -> (Env, LedgerLensScoreContractClient<'a>, Vec<Address>) {
    let env = Env::default();
    env.mock_all_auths();
    env.budget().reset_unlimited();
    env.ledger().with_mut(|l| l.timestamp = START_TS);
    let contract_id = env.register_contract(None, LedgerLensScoreContract);
    let client = LedgerLensScoreContractClient::new(&env, &contract_id);
    let admin = Address::generate(&env);
    let service = Address::generate(&env);
    client.initialize(&admin, &service);
    let signers = Vec::from_array(&env, [admin]);
    (env, client, signers)
}

fn value(env: &Env) -> Bytes {
    Bytes::from_array(env, &MIN_COOLDOWN_SECS.to_be_bytes())
}

#[test]
fn test_sustained_single_proposer_saturation_and_recovery() {
    let (env, client, signers) = setup();
    let value = value(&env);
    let mut now = START_TS;
    let mut last_id = 0u64;

    for _round in 0..ROUNDS {
        let mut accepted: Vec<u64> = Vec::new(&env);
        let mut rejected = 0u32;

        for _ in 0..ATTEMPTS_PER_ROUND {
            match client.try_propose_parameter_change(&signers, &param_key_cooldown(), &value) {
                Ok(Ok(id)) => {
                    assert!(id > last_id, "proposal ids must be strictly increasing");
                    last_id = id;
                    accepted.push_back(id);
                }
                Err(Ok(Error::TooManyPendingParameterProposals)) => rejected += 1,
                other => panic!("unexpected result at saturation: {:?}", other),
            }
            assert!(
                client.get_pending_param_prop_ids().len() <= MAX_PENDING_PARAMETER_PROPOSALS,
                "pending queue must never exceed the cap"
            );
        }

        // Exactly the cap is accepted; everything after is rejected, not evicted.
        assert_eq!(accepted.len(), MAX_PENDING_PARAMETER_PROPOSALS);
        assert_eq!(rejected, ATTEMPTS_PER_ROUND - MAX_PENDING_PARAMETER_PROPOSALS);

        // Fairness: queue order is submission order, and nothing was evicted.
        assert_eq!(client.get_pending_param_prop_ids(), accepted);
        for id in accepted.iter() {
            assert_eq!(client.get_parameter_proposal(&id).status, ParameterProposalStatus::Pending);
        }

        // Let the whole batch expire; the next proposal prunes it and succeeds.
        now += DEFAULT_UPGRADE_DELAY_SECS * 2 + 1;
        env.ledger().with_mut(|l| l.timestamp = now);
        let id = client.propose_parameter_change(&signers, &param_key_cooldown(), &value);
        last_id = id;
        assert_eq!(client.get_pending_param_prop_ids(), Vec::from_array(&env, [id]));
        for old in accepted.iter() {
            assert_eq!(client.get_parameter_proposal(&old).status, ParameterProposalStatus::Expired);
        }

        // Expire that straggler too so each round starts from an empty queue.
        now += DEFAULT_UPGRADE_DELAY_SECS * 2 + 1;
        env.ledger().with_mut(|l| l.timestamp = now);
    }
}

#[test]
fn test_cost_at_saturation_within_budget() {
    let (env, client, signers) = setup();
    let value = value(&env);
    for _ in 0..MAX_PENDING_PARAMETER_PROPOSALS {
        client.propose_parameter_change(&signers, &param_key_cooldown(), &value);
    }

    env.budget().reset_unlimited();
    let _ = client.try_propose_parameter_change(&signers, &param_key_cooldown(), &value);
    let propose_cpu = env.budget().cpu_instruction_cost();

    env.budget().reset_unlimited();
    let ids = client.get_pending_param_prop_ids();
    let list_cpu = env.budget().cpu_instruction_cost();

    assert_eq!(ids.len(), MAX_PENDING_PARAMETER_PROPOSALS);
    assert!(propose_cpu <= MAX_CPU_AT_SATURATION, "propose at saturation: {propose_cpu} cpu");
    assert!(list_cpu <= MAX_CPU_AT_SATURATION, "list at saturation: {list_cpu} cpu");
}
