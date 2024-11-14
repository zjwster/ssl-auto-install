1、下载文件到 /root/ 目录
curl -o /root/.cf_credentials https://raw.githubusercontent.com/zjwster/ssl-auto-install/main/.cf_credentials

2、使用文本编辑器（如 nano 或 vim）编辑文件
nano /root/.cf_credentials

control+X，Y，enter保存

3、下载或更新脚本
curl -sSL "https://raw.githubusercontent.com/zjwster/ssl-auto-install/main/install_ssl.sh" -o install_ssl.sh

4、赋予执行权限
chmod +x install_ssl.sh

5、以sudo权限执行脚本
sudo ./install_ssl.sh

查看定时任务
crontab -l
