package config

type Client struct {
	Width            int
	Height           int
	FrameLimit       int
	Screenshot       string
	Demo             bool
	Movement         bool
	Cycles           int
	Debug            bool
	MouseSensitivity float32
	FieldOfView      float32
}

func DefaultClient() Client {
	return Client{
		Width: 1280, Height: 720, MouseSensitivity: 0.0025, FieldOfView: 75,
	}
}
