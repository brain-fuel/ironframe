// The shop: adopts a pet for a customer through the checked definition `adopt` of
// spec/shop.lawspec, run under the production handlers of its two dependencies, and prints the
// adoption it published and read back. It reads its settings as the adapter does; it is the same
// program whether Ironframe runs it, another tool deploys it or a person runs it by hand.
//
//	shop <pet-name> <customer>
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"example.com/calm-shop/shop/adoptions"
)

func main() {
	name, customer := "rex", "ada"
	if len(os.Args) == 3 {
		name, customer = os.Args[1], os.Args[2]
	}
	symbols := map[string]*adoptions.LawSpecSymbol{}
	log := adoptions.NewAdoptionsHandler()
	adoption := adoptions.LawSpecDefinitions.Adopt(symbols, adoptions.NewPetsHandler(), log, name, customer)
	found, ok := log.Lookup(adoption.Pet).Value()
	if !ok || found != adoption {
		fmt.Fprintf(os.Stderr, "shop: adoption of pet %d was not read back\n", adoption.Pet)
		os.Exit(1)
	}
	out, _ := json.Marshal(adoption)
	fmt.Println(string(out))
}
