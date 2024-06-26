import Vec "mo:vector";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import { print } "mo:base/Debug";

import TokenHandler "../src";

module {
  type JournalVector = Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)>;

  public class TestJournal() {
    let journal : Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)> = Vec.new();

    var counter_ = 0;

    public func counter() : Nat = counter_;

    func incrementCounter(n : Nat) : Nat { counter_ += n; counter_ };

    public func log(p : Principal, e : TokenHandler.LogEvent) {
      Vec.add(journal, (Time.now(), p, e));
    };

    public func hasSize(n : Nat) : Bool = Vec.size(journal) == incrementCounter(n);

    public func debugShow(startFrom : Nat) : () {
      Vec.toArray(journal)
      |> Array.slice(_, startFrom, _.size())
      |> Iter.toArray(_) |> print(debug_show _.size() # " : " # debug_show _);
    };
  };
};
