// The shop: adopts a pet for a customer through the checked definition `adopt` of
// spec/shop.lawspec, run under the production handlers of its two dependencies, and prints the
// adoption it published and read back. It reads its settings as the adapter does; it is the same
// program whether Ironframe runs it, another tool deploys it or a person runs it by hand.
//
//	shop [<pet-name> <customer>]   adopt a pet
//	shop audit                     count the adoptions on the log, as the audit application
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"example.com/calm-shop/shop/adoptions"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "audit" {
		count, err := adoptions.Audit()
		if err != nil {
			fmt.Fprintf(os.Stderr, "shop audit: %v\n", err)
			os.Exit(1)
		}
		if count == 0 {
			fmt.Fprintln(os.Stderr, "shop audit: the log holds no adoption")
			os.Exit(1)
		}
		fmt.Printf("{\"adoptions\":%d}\n", count)
		return
	}
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
