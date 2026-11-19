package config

type Client struct {
	Width      int
	Height     int
	FrameLimit int
	Screenshot string
	Demo       bool
	Movement   bool
	Cycles     int
	Debug      bool
	Tuning     string
	Name       string
	Netsim     string
	// Host opens the embedded server to other players on this UDP address.
	Host string
	// Connect joins a server at this address instead of starting one.
	Connect string
	// Fingerprint pins the certificate of the server given by Connect.
	Fingerprint      string
	MouseSensitivity float32
	FieldOfView      float32
}

func DefaultClient() Client {
	return Client{
		Width: 1280, Height: 720, MouseSensitivity: 0.0025, FieldOfView: 75, Name: "Player",
	}
}
