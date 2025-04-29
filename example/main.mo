import Array "mo:base/Array";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Vec "mo:vector";
import Time "mo:base/Time";
import Blob "mo:base/Blob";

import ICRC84 "mo:icrc-84";

import TokenHandler "../src";

actor class Example() = self {

  // ensure compliance to ICRC84 standart.
  // actor won't compile in case of type mismatch here
  let _ : ICRC84.ICRC84 = self;

  stable var journalData : Journal = Vec.new();

  stable var assetsData : Vec.Vector<StableAssetInfo> = Vec.new();

  type Journal = Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)>;

  type AssetInfo = {
    ledgerPrincipal : Principal;
    handler : TokenHandler.TokenHandler;
  };

  type StableAssetInfo = {
    ledgerPrincipal : Principal;
    handler : TokenHandler.StableData;
  };

  var initialized : Bool = false;
  var assets : Vec.Vector<AssetInfo> = Vec.new();
  var journal : Journal = Vec.new();

  private func assertInitialized() = if (not initialized) {
    Prim.trap("Not initialized");
  };

  private func createTokenHandler(ledgerPrincipal : Principal) : TokenHandler.TokenHandler {
    TokenHandler.TokenHandler({
      ledgerApi = TokenHandler.buildLedgerApi(ledgerPrincipal);
      ownPrincipal = Principal.fromActor(self);
      initialFee = 0;
      triggerOnNotifications = true;
      log = func(p : Principal, event : TokenHandler.LogEvent) {
        Vec.add(journal, (Time.now(), p, event));
      };
    });
  };

  public shared func init() : async () {
    assert not initialized;
    journal := journalData;
    assets := Vec.map<StableAssetInfo, AssetInfo>(
      assetsData,
      func(x) {
        let r = {
          ledgerPrincipal = x.ledgerPrincipal;
          handler = createTokenHandler(x.ledgerPrincipal);
        };
        r.handler.unshare(x.handler);
        r;
      },
    );
    initialized := true;
  };

  public shared query func icrc84_supported_tokens() : async [Principal] {
    assertInitialized();
    Array.tabulate<Principal>(
      Vec.size(assets),
      func(i) = Vec.get(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrc84_token_info(token : Principal) : async ICRC84.TokenInfo {
    assertInitialized();
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return {
          deposit_fee = assetInfo.handler.fee(#deposit);
          withdrawal_fee = assetInfo.handler.fee(#withdrawal);
          allowance_fee = assetInfo.handler.fee(#allowance);
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrc84_query(tokens : [Principal]) : async ([(
    Principal,
    {
      credit : Int;
      tracked_deposit : ?Nat;
    },
  )]) {
    assertInitialized();
    let ret : Vec.Vector<(Principal, { credit : Int; tracked_deposit : ?Nat })> = Vec.new();
    for (token in tokens.vals()) {
      let ?assetInfo = getAssetInfo(token) else throw Error.reject("Unknown token");
      let credit = assetInfo.handler.userCredit(caller);
      if (credit > 0) {
        let tracked_deposit = assetInfo.handler.trackedDeposit(caller);
        Vec.add(ret, (token, { credit; tracked_deposit }));
      };
    };
    Vec.toArray(ret);
  };

  public shared ({ caller }) func icrc84_notify(args : ICRC84.NotifyArgs) : async ICRC84.NotifyResponse {
    assertInitialized();
    let ?assetInfo = getAssetInfo(args.token) else throw Error.reject("Unknown token");
    let result = try {
      await* assetInfo.handler.notify(caller);
    } catch (err) {
      return #Err(#CallLedgerError({ message = Error.message(err) }));
    };
    switch (result) {
      case (?(deposit_inc, credit_inc)) {
        #Ok({
          deposit_inc;
          credit_inc;
          credit = assetInfo.handler.userCredit(caller);
        });
      };
      case null {
        #Err(#NotAvailable({ message = "" }));
      };
    };
  };

  public shared ({ caller }) func icrc84_deposit(args : ICRC84.DepositArgs) : async ICRC84.DepositResponse {
    assertInitialized();
    let ?assetInfo = getAssetInfo(args.token) else throw Error.reject("Unknown token");
    let res = await* assetInfo.handler.depositFromAllowance(caller, args.from, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(credit_inc, txid)) #Ok({
        txid;
        credit_inc;
        credit = assetInfo.handler.userCredit(caller);
      });
      case (#err err) {
        switch (err) {
          case (#BadFee({ expected_fee })) #Err(#BadFee({ expected_fee }));
          case (#InsufficientFunds(_)) #Err(#TransferError({ message = "Insufficient funds" }));
          case (#InsufficientAllowance(_)) #Err(#TransferError({ message = "Insufficient allowance" }));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case _ #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  public shared ({ caller }) func icrc84_withdraw(args : ICRC84.WithdrawArgs) : async ICRC84.WithdrawResponse {
    assertInitialized();
    let ?assetInfo = getAssetInfo(args.token) else throw Error.reject("Unknown token");

    switch (args.to.subaccount) {
      case (?subaccount) {
        let bytes = Blob.toArray(subaccount);
        if (bytes.size() != 32) throw Error.reject("Invalid subaccount");
      };
      case null {};
    };

    let res = await* assetInfo.handler.withdrawFromCredit(caller, args.to, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(txid, amount)) #Ok({ txid; amount });
      case (#err err) {
        switch (err) {
          case (#InsufficientCredit) #Err(#InsufficientCredit({}));
          case (#BadFee({ expected_fee })) #Err(#BadFee({ expected_fee }));
          case (#TooLowQuantity) #Err(#AmountBelowMinimum({}));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case _ #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  // A timer for consolidating backlog subaccounts
  ignore Timer.recurringTimer<system>(
    #seconds 60,
    func() : async () {
      for (asset in Vec.vals(assets)) {
        await* asset.handler.trigger(10);
      };
    },
  );

  private func getAssetInfo(icrc1Ledger : Principal) : ?AssetInfo {
    for (assetInfo in Vec.vals(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, icrc1Ledger)) {
        return ?assetInfo;
      };
    };
    return null;
  };

  public shared func registerAsset(ledger : Principal) : async {
    #Ok : Nat;
    #Err : { #AlreadyRegistered : Nat };
  } {
    assertInitialized();
    // validate ledger
    let canister = actor (Principal.toText(ledger)) : (actor { icrc1_metadata : () -> async [Any] });
    try {
      ignore await canister.icrc1_metadata();
    } catch (err) {
      throw err;
    };
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(ledger, assetInfo.ledgerPrincipal)) return #Err(#AlreadyRegistered(i));
    };
    let id = Vec.size(assets);

    Vec.add<AssetInfo>(
      assets,
      {
        ledgerPrincipal = ledger;
        handler = createTokenHandler(ledger);
      },
    );
    #Ok(id);
  };

  system func preupgrade() {
    journalData := journal;
    assetsData := Vec.map<AssetInfo, StableAssetInfo>(
      assets,
      func(x) = {
        ledgerPrincipal = x.ledgerPrincipal;
        handler = x.handler.share();
      },
    );
  };
};
