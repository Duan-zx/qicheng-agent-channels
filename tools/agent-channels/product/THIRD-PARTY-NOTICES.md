# Third-party dependency notice

The Apache-2.0 `LICENSE` shipped with Qicheng Lite covers Qicheng-authored source and the locally compiled viewer. It does **not** relicense Docker, the base image, Debian, Firefox, fonts, or packages installed into the container.

Qicheng Lite source packages contain build instructions, not a Docker engine or a prebuilt third-party container image. The first image build downloads the following software from its normal upstream repositories. The license files and copyright records installed in the resulting image, especially `/usr/share/doc/<package>/copyright`, are the controlling copies.

| Dependency | Distribution role | Upstream license family |
|---|---|---|
| Python `3.12-slim-bookworm` image | Container base and Python runtime | Python Software Foundation License; Debian components retain their own licenses |
| Debian GNU/Linux Bookworm | Base userspace and package source | Package-specific free-software licenses |
| Firefox ESR | Browser inside each workspace | Mozilla Public License 2.0, with separately licensed bundled components |
| X.Org Xvfb and X11 utilities | Virtual display | MIT/X11 and package-specific X.Org licenses |
| Openbox | Window manager | GNU GPL 2.0 or later |
| xdotool | Desktop input helper | BSD 3-Clause |
| wmctrl | Window control helper | GNU GPL 2.0 |
| ImageMagick | Screenshot/image utility | ImageMagick License (Apache-2.0 style) |
| xterm | Terminal emulator | MIT/X Consortium license |
| tini | Container init | MIT License |
| DejaVu fonts | UI fonts | Bitstream Vera/DejaVu font licenses |
| WenQuanYi Micro Hei | CJK font | GNU GPL 3.0 with font embedding exception |
| xclip | X11 clipboard helper | GNU GPL 2.0 |

Docker is an external prerequisite. Qicheng Lite does not bundle Docker Desktop and does not claim that Docker Desktop is open source or unconditionally free. Docker Desktop use is governed by Docker's current subscription and license terms. Docker Engine/Moby and Docker Compose have their own upstream licenses.

The Windows viewer uses the locally installed Microsoft .NET Framework compiler and runtime; these Microsoft components are not redistributed in this package. Refer to Microsoft's applicable license terms.

This notice is informational and does not replace any upstream license text. When distributing a built image, retain the license/copyright material installed by the upstream image and Debian packages.
