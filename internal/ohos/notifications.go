package ohos

import (
	"github.com/egoist/mygo/internal/platform"
)

// Notifications go through the host: ArkTS publishes them with
// notificationManager, which needs the user's consent once.
type notifier struct{}

func (b *backend) NotificationsSupported() bool { return true }

func (b *backend) ShowNotification(n *platform.Notification, done func(error)) {
	args := map[string]string{
		"id":    n.ID,
		"title": n.Title,
		"body":  n.Body,
	}
	b.push(func() {
		go func() {
			_, err := callHost("notification.show", args)
			if done != nil {
				b.push(func() { done(err) })
			}
		}()
	})
}

func (b *backend) RemoveNotification(id string) {
	go func() { _, _ = callHost("notification.remove", map[string]string{"id": id}) }()
}

func (b *backend) RemoveAllNotifications() {
	go func() { _, _ = callHost("notification.clear", nil) }()
}
