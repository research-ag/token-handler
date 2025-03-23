import Array "mo:base/Array";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Int "mo:base/Int";
import Principal "mo:base/Principal";
import Vec "mo:vector";

import TokenHandler "../../src";

module {
  public class InveariantChecker() {
    var deposited = 0;
    var totalConsolidated = 0;
    var totalCredited = 0;
    var lockedFunds = 0;
    var totalWithdrawn = 0;

    var creditSum = 0;
    var handlerPool : Int = 0;
    var pool = 0;
    var fees = 0;

    public func checkInvariant(p : Principal, event : TokenHandler.LogEvent) : Bool {
      switch event {
        case (
          #newDeposit {
            depositInc;
            creditInc;
            ledgerFee;
            surcharge;
          }
        ) {
          deposited += depositInc;
          creditSum += creditInc;
          fees += ledgerFee;
          handlerPool += surcharge;
        };
        case (#depositInc(value)) {
          deposited += value;
          creditSum += value;
        };
        case (
          #consolidated {
            deducted;
            credited;
            fee;
          }
        ) {
          deposited -= deducted;
          totalConsolidated += credited;
          fees -= fee;
        };

        case (#credited value) {
          pool -= value;
          creditSum += value;
        };
        case (#debited value) {
          pool += value;
          creditSum -= value;
        };

        case (
          #feeUpdated {
            delta;
          }
        ) {
          handlerPool -= delta;
          assert fees + delta >= 0;
          fees := Int.abs(fees + delta);
        };
        case (#surchargeUpdated _) {};

        case (
          #allowanceDrawn {
            amount;
            credited;
            surcharge;
          }
        ) {
          totalCredited += amount;
          creditSum += credited;
          handlerPool += surcharge;
        };

        case (
          #withdraw {
            amount;
            withdrawn;
            surcharge;
          }
        ) {
          lockedFunds -= amount;
          totalWithdrawn += withdrawn;
          handlerPool += surcharge;
        };
        case (#locked value) {
          assert lockedFunds + value >= 0;
          lockedFunds := Int.abs(lockedFunds + value);

          if (p == Principal.fromBlob("")) {
            assert pool - value >= 0;
            pool := Int.abs(pool - value);
          } else {
            assert creditSum - value >= 0;
            creditSum := Int.abs(creditSum - value);
          };
        };

        case (#error _) {};
      };

      let assets = deposited + totalConsolidated + totalCredited - lockedFunds - totalWithdrawn : Nat;
      let liabilities = creditSum + handlerPool + pool + fees : Int;

      assets == liabilities;
    };
  };

  type JournalVector = Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)>;

  public class TestJournal() {
    let journal : Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)> = Vec.new();
    let invariantChecker : InveariantChecker = InveariantChecker();

    var counter_ = 0;

    public func counter() : Nat = counter_;

    var verbose = false;

    public func verboseOn() = verbose := true;

    public func verboseOff() = verbose := false;

    public func log(p : Principal, e : TokenHandler.LogEvent) {
      let event = (Time.now(), p, e);
      if (verbose) Debug.print("logging: " # debug_show event);
      Vec.add(journal, event);
    };

    public func hasEvents(events : [TokenHandler.LogEvent]) : Bool {
      let prevCounter = counter_; // previous size
      counter_ := Vec.size(journal);
      if (Vec.size(journal) != prevCounter + events.size()) return false;
      if (events.size() == 0) return true;
      for (i in Iter.range(prevCounter, prevCounter + events.size() - 1)) {
        let (_, p, event) = Vec.get(journal, i);
        if (event != events[i - prevCounter]) return false;
        if (not invariantChecker.checkInvariant(p, event)) return false;
      };
      true;
    };

    public func size() : Nat = Vec.size(journal);

    public func debugShow(startFrom : Nat) : () {
      Debug.print(
        debug_show (
          Vec.toArray(journal)
          |> Array.slice(_, startFrom, _.size())
          |> Iter.toArray(_)
        )
      );
    };
  };
};
