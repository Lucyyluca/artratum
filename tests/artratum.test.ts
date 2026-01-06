
import { beforeEach, describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const CONTRACT = "artratum";
const TOKEN = "test-token";

const tokenSource = `
(use-trait sip-010 .${CONTRACT}.sip-010-trait)
(impl-trait .${CONTRACT}.sip-010-trait)

(define-constant token-owner tx-sender)
(define-data-var transfers-enabled bool true)
(define-fungible-token test-token)

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (var-get transfers-enabled) (err u500))
    (asserts! (or (is-eq sender tx-sender) (is-eq sender contract-caller)) (err u501))
    (ft-transfer? test-token amount sender recipient)))

(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender token-owner) (err u403))
    (ft-mint? test-token amount recipient)))

(define-public (set-transfers-enabled (enabled bool))
  (begin
    (asserts! (is-eq tx-sender token-owner) (err u403))
    (var-set transfers-enabled enabled)
    (ok enabled)))

(define-read-only (get-name) (ok "Test Token"))
(define-read-only (get-symbol) (ok "TST"))
(define-read-only (get-decimals) (ok u6))
(define-read-only (get-total-supply) (ok (ft-get-supply test-token)))
(define-read-only (get-balance (owner principal)) (ok (ft-get-balance test-token owner)))
(define-read-only (get-token-uri) (ok none))
`;

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;

const tokenPrincipal = (owner: string) => Cl.contractPrincipal(owner, TOKEN);

const deployToken = () =>
  simnet.deployContract(TOKEN, tokenSource, { clarityVersion: 3 }, deployer);

const grantManagerRole = (manager: string) =>
  simnet.callPublicFn(CONTRACT, "grant-role", [Cl.standardPrincipal(manager), Cl.uint(2)], deployer);

const mintTo = (amount: number | bigint, recipient: string) =>
  simnet.callPublicFn(TOKEN, "mint", [Cl.uint(amount), Cl.standardPrincipal(recipient)], deployer);

const mineToHeight = (target: number) => {
  const diff = target - simnet.blockHeight;
  if (diff > 0) simnet.mineEmptyBlocks(diff);
};

beforeEach(async () => {
  await simnet.initSession(process.cwd(), "Clarinet.toml");
});

describe("access control", () => {
  it("only owner can grant roles", () => {
    const okGrant = grantManagerRole(wallet1);
    expect(okGrant.result).toBeOk(Cl.bool(true));

    const unauthorized = simnet.callPublicFn(
      CONTRACT,
      "grant-role",
      [Cl.standardPrincipal(wallet2), Cl.uint(2)],
      wallet1,
    );
    expect(unauthorized.result).toBeErr(Cl.uint(2)); // err-unauthorized
  });

  it("pauses and resumes state mutations", () => {
    deployToken();
    grantManagerRole(wallet1);

    const paused = simnet.callPublicFn(CONTRACT, "pause-contract", [], deployer);
    expect(paused.result).toBeOk(Cl.bool(true));

    const pausedCreate = simnet.callPublicFn(
      CONTRACT,
      "create-grant-with-token",
      [
        Cl.uint(1),
        Cl.standardPrincipal(wallet1),
        Cl.uint(100),
        Cl.uint(simnet.blockHeight + 1),
        Cl.uint(1),
        Cl.uint(4),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(pausedCreate.result).toBeErr(Cl.uint(12)); // err-contract-paused

    const unpaused = simnet.callPublicFn(CONTRACT, "unpause-contract", [], deployer);
    expect(unpaused.result).toBeOk(Cl.bool(true));

    mintTo(200, wallet1);
    const resumedCreate = simnet.callPublicFn(
      CONTRACT,
      "create-grant-with-token",
      [
        Cl.uint(1),
        Cl.standardPrincipal(wallet1),
        Cl.uint(100),
        Cl.uint(simnet.blockHeight + 1),
        Cl.uint(1),
        Cl.uint(4),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(resumedCreate.result).toBeOk(Cl.bool(true));
  });
});

describe("grant creation", () => {
  it("locks tokens and prevents duplicate ids", () => {
    deployToken();
    grantManagerRole(wallet1);
    mintTo(500, wallet1);

    const startAt = simnet.blockHeight + 1;
    const create = simnet.callPublicFn(
      CONTRACT,
      "create-grant-with-token",
      [
        Cl.uint(42),
        Cl.standardPrincipal(wallet1),
        Cl.uint(300),
        Cl.uint(startAt),
        Cl.uint(1),
        Cl.uint(6),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(create.result).toBeOk(Cl.bool(true));

    const locked = simnet.callReadOnlyFn(
      CONTRACT,
      "get-locked-balance",
      [tokenPrincipal(deployer)],
      wallet1,
    );
    expect(locked.result).toBeUint(300);

    const duplicate = simnet.callPublicFn(
      CONTRACT,
      "create-grant-with-token",
      [
        Cl.uint(42),
        Cl.standardPrincipal(wallet1),
        Cl.uint(100),
        Cl.uint(startAt),
        Cl.uint(1),
        Cl.uint(6),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(duplicate.result).toBeErr(Cl.uint(14)); // err-duplicate-grant
  });

  it("auto-increments grant ids and updates stats", () => {
    deployToken();
    grantManagerRole(wallet1);
    mintTo(200, wallet1);

    const auto = simnet.callPublicFn(
      CONTRACT,
      "create-grant-auto",
      [
        Cl.standardPrincipal(wallet1),
        Cl.uint(150),
        Cl.uint(simnet.blockHeight + 1),
        Cl.uint(0),
        Cl.uint(4),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(auto.result).toBeOk(Cl.uint(1));

    const stats = simnet.callReadOnlyFn(CONTRACT, "get-contract-stats", [], wallet1);
    expect(stats.result).toBeOk(
      Cl.tuple({
        "next-grant-id": Cl.uint(2),
        "total-grants": Cl.uint(1),
        "contract-paused": Cl.bool(false),
        "max-batch-size": Cl.uint(50),
        "contract-owner": Cl.standardPrincipal(deployer),
      }),
    );
  });
});

describe("vesting and withdrawals", () => {
  it("vests linearly after cliff and transfers tokens on withdraw", () => {
    deployToken();
    grantManagerRole(wallet1);
    mintTo(100, wallet1);

    const start = simnet.blockHeight + 5;
    const create = simnet.callPublicFn(
      CONTRACT,
      "create-grant-with-token",
      [
        Cl.uint(1),
        Cl.standardPrincipal(wallet1),
        Cl.uint(100),
        Cl.uint(start),
        Cl.uint(1),
        Cl.uint(4),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(create.result).toBeOk(Cl.bool(true));

    mineToHeight(start);
    const beforeStart = simnet.callReadOnlyFn(CONTRACT, "withdrawable", [Cl.uint(1)], wallet1);
    expect(beforeStart.result).toBeOk(Cl.uint(0));

    const atStart = simnet.callReadOnlyFn(CONTRACT, "withdrawable", [Cl.uint(1)], wallet1);
    expect(atStart.result).toBeOk(Cl.uint(0));

    simnet.mineEmptyBlocks(1);
    const afterCliff = simnet.callReadOnlyFn(CONTRACT, "withdrawable", [Cl.uint(1)], wallet1);
    const availableAfterCliff = (afterCliff.result as any).value;
    expect(Number((availableAfterCliff as any).value)).toBeGreaterThan(0);

    const firstWithdraw = simnet.callPublicFn(
      CONTRACT,
      "withdraw",
      [Cl.uint(1), tokenPrincipal(deployer)],
      wallet1,
    );
    const firstWithdrawAmount = (firstWithdraw.result as any).value;
    expect(firstWithdraw.result).toBeOk(firstWithdrawAmount);

    const lockedAfterWithdraw = simnet.callReadOnlyFn(
      CONTRACT,
      "get-locked-balance",
      [tokenPrincipal(deployer)],
      wallet1,
    );
    const firstAmount = Number((firstWithdrawAmount as any).value);
    expect(lockedAfterWithdraw.result).toBeUint(100 - firstAmount);

    simnet.mineEmptyBlocks(5);
    const finalWithdrawable = simnet.callReadOnlyFn(CONTRACT, "withdrawable", [Cl.uint(1)], wallet1);
    const finalAmount = (finalWithdrawable.result as any).value;
    expect(finalWithdrawable.result).toBeOk(finalAmount);

    const finalWithdraw = simnet.callPublicFn(
      CONTRACT,
      "withdraw",
      [Cl.uint(1), tokenPrincipal(deployer)],
      wallet1,
    );
    expect(finalWithdraw.result).toBeOk(finalAmount);

    const lockedAfterAll = simnet.callReadOnlyFn(
      CONTRACT,
      "get-locked-balance",
      [tokenPrincipal(deployer)],
      wallet1,
    );
    expect(lockedAfterAll.result).toBeUint(0);
  });
});

describe("revocation", () => {
  it("releases unvested tokens and marks grant revoked", () => {
    deployToken();
    grantManagerRole(wallet1);
    mintTo(100, wallet1);

    const start = simnet.blockHeight + 5;
    const create = simnet.callPublicFn(
      CONTRACT,
      "create-grant-with-token",
      [
        Cl.uint(7),
        Cl.standardPrincipal(wallet1),
        Cl.uint(100),
        Cl.uint(start),
        Cl.uint(0),
        Cl.uint(4),
        tokenPrincipal(deployer),
      ],
      wallet1,
    );
    expect(create.result).toBeOk(Cl.bool(true));

    mineToHeight(start + 2);

    const revoked = simnet.callPublicFn(CONTRACT, "revoke-grant", [Cl.uint(7)], deployer);
    expect(revoked.result).toBeOk(Cl.bool(true));

    const vestedAfter = simnet.callReadOnlyFn(CONTRACT, "vested", [Cl.uint(7)], wallet1);
    const vestedValue = (vestedAfter.result as any).value;
    const status = simnet.callReadOnlyFn(CONTRACT, "get-grant-status", [Cl.uint(7)], wallet1);
    expect(status.result).toBeOk(
      Cl.tuple({
        recipient: Cl.standardPrincipal(wallet1),
        total: Cl.uint(100),
        vested: vestedValue,
        withdrawn: Cl.uint(0),
        withdrawable: Cl.uint(0),
        revoked: Cl.bool(true),
        "token-contract": tokenPrincipal(deployer),
        "start-height": Cl.uint(start),
        cliff: Cl.uint(0),
        duration: Cl.uint(4),
      }),
    );

    const locked = simnet.callReadOnlyFn(
      CONTRACT,
      "get-locked-balance",
      [tokenPrincipal(deployer)],
      wallet1,
    );
    expect(locked.result).toBeUint(Number((vestedValue as any).value));
  });
});
