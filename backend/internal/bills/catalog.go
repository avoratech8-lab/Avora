package bills

// Category is what a biller sells.
type Category string

const (
	Airtime     Category = "airtime"
	Data        Category = "data"
	Electricity Category = "electricity"
	TV          Category = "tv"
	Internet    Category = "internet"
	Education   Category = "education" // exam PINs: WAEC, NECO, JAMB
	Betting     Category = "betting"   // sportsbook wallet top-ups, 18+ only
)

type Plan struct {
	Code   string `json:"code"`
	Name   string `json:"name"`
	Amount int64  `json:"amount"` // kobo
}

// Biller is a network, DisCo or TV provider. Billers with plans charge the
// plan's price; the others take any amount between MinAmount and MaxAmount.
type Biller struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Category      Category `json:"category"`
	CustomerLabel string   `json:"customer_label"`
	Plans         []Plan   `json:"plans"`
	MinAmount     int64    `json:"min_amount"`
	MaxAmount     int64    `json:"max_amount"`
	CashbackBps   int64    `json:"cashback_bps"` // paid back to the wallet once the biller confirms
}

// byPhone billers are paid to a phone number, with no name to check.
func (b Biller) byPhone() bool { return b.CustomerLabel == "Phone number" }

func (b Biller) needsLookup() bool { return !b.byPhone() }

// MaxCashback caps cashback on one payment.
const MaxCashback = 500_00

// Cashback is what a payment of amount earns back.
func (b Biller) Cashback(amount int64) int64 { return min(amount*b.CashbackBps/10_000, MaxCashback) }

func (b Biller) plan(code string) (Plan, bool) {
	for _, p := range b.Plans {
		if p.Code == code {
			return p, true
		}
	}
	return Plan{}, false
}

// SandboxCatalog is the sandbox's biller list. Prices are samples, not live
// tariffs; the real list comes from the bill aggregator. Cashback rates are
// placeholders to be set within the aggregator's commission.
func SandboxCatalog() []Biller {
	naira := func(n int64) int64 { return n * 100 }
	data := func(net string) []Plan {
		return []Plan{
			{net + "-1gb-1d", "1GB · 1 day", naira(500)},
			{net + "-2gb-7d", "2GB · 7 days", naira(1500)},
			{net + "-3.5gb-30d", "3.5GB · 30 days", naira(2500)},
			{net + "-10gb-30d", "10GB · 30 days", naira(4500)},
			{net + "-25gb-30d", "25GB · 30 days", naira(9000)},
		}
	}
	var out []Biller
	networks := [][2]string{{"mtn", "MTN"}, {"airtel", "Airtel"}, {"glo", "Glo"}, {"9mobile", "9mobile"}}
	for _, n := range networks {
		out = append(out, Biller{ID: n[0] + "-airtime", Name: n[1], Category: Airtime, CustomerLabel: "Phone number",
			Plans: []Plan{}, MinAmount: naira(50), MaxAmount: naira(50_000), CashbackBps: 200})
	}
	for _, n := range networks {
		out = append(out, Biller{ID: n[0] + "-data", Name: n[1], Category: Data, CustomerLabel: "Phone number", Plans: data(n[0]),
			CashbackBps: 300})
	}
	discos := [][2]string{
		{"ikedc", "Ikeja Electric"}, {"ekedc", "Eko Electric"}, {"aedc", "Abuja Electric"}, {"ibedc", "Ibadan Electric"},
		{"phed", "Port Harcourt Electric"}, {"kedco", "Kano Electric"}, {"eedc", "Enugu Electric"},
	}
	for _, d := range discos {
		out = append(out, Biller{ID: d[0], Name: d[1], Category: Electricity, CustomerLabel: "Meter number",
			Plans: []Plan{}, MinAmount: naira(1_000), MaxAmount: naira(500_000)})
	}
	out = append(out,
		Biller{ID: "dstv", Name: "DStv", Category: TV, CustomerLabel: "Smartcard number", Plans: []Plan{
			{"dstv-padi", "Padi", naira(4400)}, {"dstv-yanga", "Yanga", naira(6000)}, {"dstv-confam", "Confam", naira(11000)},
			{"dstv-compact", "Compact", naira(19000)}, {"dstv-premium", "Premium", naira(44500)},
		}},
		Biller{ID: "gotv", Name: "GOtv", Category: TV, CustomerLabel: "IUC number", Plans: []Plan{
			{"gotv-smallie", "Smallie", naira(1900)}, {"gotv-jinja", "Jinja", naira(3900)}, {"gotv-jolli", "Jolli", naira(5800)},
			{"gotv-max", "Max", naira(8500)}, {"gotv-supa", "Supa", naira(11400)},
		}},
		Biller{ID: "startimes", Name: "StarTimes", Category: TV, CustomerLabel: "Smartcard number", Plans: []Plan{
			{"startimes-nova", "Nova", naira(1900)}, {"startimes-basic", "Basic", naira(3700)},
			{"startimes-classic", "Classic", naira(5500)},
		}},
		Biller{ID: "spectranet", Name: "Spectranet", Category: Internet, CustomerLabel: "Customer ID", Plans: []Plan{
			{"spectranet-30gb", "30GB · 30 days", naira(10000)}, {"spectranet-65gb", "65GB · 30 days", naira(20000)},
			{"spectranet-unlimited", "Unlimited · 30 days", naira(35000)},
		}},
		Biller{ID: "smile", Name: "Smile", Category: Internet, CustomerLabel: "Account number", Plans: []Plan{
			{"smile-6gb", "6GB · 30 days", naira(3000)}, {"smile-20gb", "20GB · 30 days", naira(8000)},
			{"smile-unlimited", "Unlimited Lite · 30 days", naira(20000)},
		}},
		Biller{ID: "waec", Name: "WAEC", Category: Education, CustomerLabel: "Phone number", Plans: []Plan{
			{"waec-result", "Result checker PIN", naira(3900)},
		}},
		Biller{ID: "neco", Name: "NECO", Category: Education, CustomerLabel: "Phone number", Plans: []Plan{
			{"neco-result", "Result token", naira(1300)},
		}},
		Biller{ID: "jamb", Name: "JAMB", Category: Education, CustomerLabel: "Profile code", Plans: []Plan{
			{"jamb-utme", "UTME ePIN", naira(7700)}, {"jamb-de", "Direct Entry ePIN", naira(7700)},
		}},
	)
	books := [][2]string{
		{"bet9ja", "Bet9ja"}, {"sportybet", "SportyBet"}, {"betking", "BetKing"}, {"1xbet", "1xBet"},
		{"nairabet", "NairaBet"}, {"msport", "MSport"},
	}
	for _, b := range books {
		out = append(out, Biller{ID: b[0], Name: b[1], Category: Betting, CustomerLabel: "User ID",
			Plans: []Plan{}, MinAmount: naira(100), MaxAmount: naira(500_000)})
	}
	return out
}
