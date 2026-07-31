# Attribution

Displaying the tile services' credits is a condition of using them, not a nicety.

## What the library does

Every photorealistic tile carries its data-source credits in its glTF `asset.copyright`. The
library aggregates those over the tiles currently *in view* — Google's display rule — orders the
sources by how many tiles credit them, and draws the result as a small overlay in the diorama's
corner. The overlay cannot be suppressed, tracks refinement and panning as the visible set
changes, and is prefixed with the provider's own name (``Tiles3DProvider/attribution``).

## What your app must do

Google's Map Tiles API policies additionally require the **Google logo** on screen wherever its
tiles are shown. A Swift package that ships no resources cannot carry the logo asset, so placing
it is the integrating app's obligation. Download the official lockups and read the placement rules
in Google's attribution guidelines:

<https://developers.google.com/maps/documentation/tile/policies>

Raster imagery sources (ESRI, MapTiler) carry their own terms of use; consult each service's
attribution requirements for anything you ship.
