import ICRC1 "icrc1-api";
import Types "types";
import TokenHandler "lib";

// A transient type for TokenHandler callbacks, shared functions, API
module {

  public type TokenHandlerContextOptions = {
    ledgerApi : ICRC1.API;
    // ownPrincipal : Principal;
    // initialFee : Nat;
    // triggerOnNotifications : Bool;
    // log : (Principal, LogEvent) -> ();
  };

  public func new(handler : TokenHandler.TokenHandler, options : TokenHandlerContextOptions) : Types.TokenHandlerContext {
    {
      api = options.ledgerApi;
      assertInvariant = func() : Bool = TokenHandler.assertInvariant(handler);
      onFeeChanged = func(oldFee : Nat, newFee : Nat) = TokenHandler.onFeeChanged(handler, oldFee : Nat, newFee : Nat);
    };
  };

};
