# ss-panel-v3-mod-node-connect
用于ss-panel-v3-mod面板的节点对接一键脚本，支持webapi和数据库对接。

## 使用方法

先在面板中创建节点并记住节点的id，执行脚本按提示选择1（webapi对接）或2（数据库对接）
然后输入相应的参数，回车执行，等待脚本安装完成重启vps后即可成功。
支持aws，centos7，

外壳
yum -y安装wget &&
wget -N --no-check-certificate https://raw.githubusercontent.com/Tyrant-2017/ss-panel-v3-mod-node-connect/master/ss-panel-v3-mod-node-connect.sh &&
chmod +x ss-panel-v3-mod-node-connect.sh &&
bash ss-panel-v3-mod-node-connect.sh
```
