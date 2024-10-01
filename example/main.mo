import Array "mo:base/Array";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Timer "mo:base/Timer";
import Vec "mo:vector";
import Time "mo:base/Time";
import Blob "mo:base/Blob";

import TokenHandler "../src";

actor class Example() = self {
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

  type TokenInfo = {
    deposit_fee : Nat;
    withdrawal_fee : Nat;
    allowance_fee : Nat;
  };

  type NotifyResult = {
    #Ok : {
      deposit_inc : Nat;
      credit_inc : Nat;
      credit : Int;
    };
    #Err : {
      #CallLedgerError : { message : Text };
      #NotAvailable : { message : Text };
    };
  };

  type DepositArgs = {
    token : Principal;
    amount : Nat;
    from : Account;
    expected_fee : ?Nat;
  };

  type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  type DepositResponse = {
    #Ok : {
      txid : Nat;
      credit_inc : Nat;
      credit : Int;
    };
    #Err : {
      #AmountBelowMinimum : {};
      #BadFee : { expected_fee : Nat };
      #CallLedgerError : { message : Text };
      #TransferError : { message : Text };
    };
  };

  type WithdrawArgs = {
    to : Account;
    amount : Nat;
    token : Principal;
    expected_fee : ?Nat;
  };

  type WithdrawResult = {
    #Ok : {
      txid : Nat;
      amount : Nat;
    };
    #Err : {
      #CallLedgerError : { message : Text };
      #BadFee : { expected_fee : Nat };
      #InsufficientCredit : {};
      #AmountBelowMinimum : {};
    };
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

  public shared query func principalToSubaccount(p : Principal) : async ?Blob = async ?TokenHandler.toSubaccount(p);

  public shared query func icrc84_supported_tokens() : async [Principal] {
    assertInitialized();
    Array.tabulate<Principal>(
      Vec.size(assets),
      func(i) = Vec.get(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrc84_token_info(token : Principal) : async TokenInfo {
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

  public shared query ({ caller }) func icrc84_credit(token : Principal) : async Int {
    assertInitialized();
    let ?assetInfo = getAssetInfo(token) else throw Error.reject("Unknown token");
    assetInfo.handler.userCredit(caller);
  };

  public shared query ({ caller }) func icrc84_all_credits() : async [(Principal, Int)] {
    assertInitialized();
    let res : Vec.Vector<(Principal, Int)> = Vec.new();
    for (assetInfo in Vec.vals(assets)) {
      let credit = assetInfo.handler.userCredit(caller);
      if (credit != 0) {
        Vec.add(res, (assetInfo.ledgerPrincipal, credit));
      };
    };
    Vec.toArray(res);
  };

  public shared query ({ caller }) func icrc84_trackedDeposit(token : Principal) : async {
    #Ok : Nat;
    #Err : { #NotAvailable : { message : Text } };
  } {
    assertInitialized();
    let ?assetInfo = getAssetInfo(token) else throw Error.reject("Unknown token");
    switch (assetInfo.handler.trackedDeposit(caller)) {
      case (?d) #Ok(d);
      case (null) #Err(#NotAvailable({ message = "Unknown caller" }));
    };
  };

  public shared ({ caller }) func icrc84_notify(args : { token : Principal }) : async NotifyResult {
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
      case (null) {
        #Err(#NotAvailable({ message = "" }));
      };
    };
  };

  public shared ({ caller }) func icrc84_deposit(args : DepositArgs) : async DepositResponse {
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
          case (#TooLowQuantity) #Err(#AmountBelowMinimum({}));
          case (#BadFee({ expected_fee })) #Err(#BadFee({ expected_fee }));
          case (#InsufficientFunds({ balance })) #Err(#TransferError({ message = "Insufficient funds" }));
          case (#InsufficientAllowance({ allowance })) #Err(#TransferError({ message = "Insufficient allowance" }));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case _ #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  public shared ({ caller }) func icrc84_withdraw(args : WithdrawArgs) : async WithdrawResult {
    assertInitialized();
    let ?assetInfo = getAssetInfo(args.token) else throw Error.reject("Unknown token");

    switch (args.to.subaccount) {
      case (?subaccount) {
        let bytes = Blob.toArray(subaccount);
        if (bytes.size() != 32) throw Error.reject("Invalid subaccount");
      };
      case (null) {};
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
    {
      ledgerPrincipal = ledger;
      handler = createTokenHandler(ledger);
    }
    |> Vec.add<AssetInfo>(assets, _);
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
