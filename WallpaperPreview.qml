import QtQuick
import qs.Commons

// Wallpaper preview card used by the Background Lock panel.
Rectangle {
  id: previewRoot

  property string source: ""
  property string label: ""
  property color fg: Color.foreground

  implicitHeight: Style.space(90)
  radius: Style.space(8)
  clip: true
  color: Color.background
  border.color: Qt.darker(previewRoot.fg, 1.3)
  border.width: 1

  Image {
    anchors.fill: parent
    source: previewRoot.source
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: 640
    sourceSize.height: 180
    visible: previewRoot.source !== ""
  }

  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: Style.space(22)
    color: Qt.rgba(0, 0, 0, 0.55)
    Text {
      anchors.centerIn: parent
      text: previewRoot.label
      font.pixelSize: Style.font.caption
      font.family: Style.font.family
      color: "#ffffff"
    }
  }
}
